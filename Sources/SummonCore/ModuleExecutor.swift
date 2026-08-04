import Foundation

/// Executes object→action module effects (open, reveal, copy). Headless-safe via `/usr/bin/open`.
public protocol ModuleExecuting: Sendable {
    func open(pathOrURL: String) throws
    func reveal(path: String) throws
    func copyToPasteboard(text: String) throws
}

/// Records calls for tests; does not touch the OS.
public final class RecordingModuleExecutor: ModuleExecuting, @unchecked Sendable {
    public struct Call: Sendable, Equatable {
        public let op: String
        public let value: String
    }

    private let lock = NSLock()
    public private(set) var calls: [Call] = []
    public var pasteboard: String = ""
    public var killedPIDs: [Int32] = []
    public var trashedPaths: [String] = []

    public init() {}

    public func open(pathOrURL: String) throws {
        lock.lock(); defer { lock.unlock() }
        calls.append(Call(op: "open", value: pathOrURL))
    }

    public func reveal(path: String) throws {
        lock.lock(); defer { lock.unlock() }
        calls.append(Call(op: "reveal", value: path))
    }

    public func copyToPasteboard(text: String) throws {
        lock.lock(); defer { lock.unlock() }
        pasteboard = text
        calls.append(Call(op: "copy", value: text))
    }

    public func recordKill(pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        killedPIDs.append(pid)
        calls.append(Call(op: "kill", value: "\(pid)"))
    }

    public func recordTrash(path: String) {
        lock.lock(); defer { lock.unlock() }
        trashedPaths.append(path)
        calls.append(Call(op: "trash", value: path))
    }

    public func recordOp(_ op: String, value: String) {
        lock.lock(); defer { lock.unlock() }
        calls.append(Call(op: op, value: value))
    }
}

/// Production executor: `/usr/bin/open` and a pasteboard sink (injected for tests).
public struct ProcessModuleExecutor: ModuleExecuting, Sendable {
    public var pasteboardWriter: @Sendable (String) throws -> Void

    public init(pasteboardWriter: @escaping @Sendable (String) throws -> Void = { _ in
        throw CoreError.io("pasteboard writer not configured")
    }) {
        self.pasteboardWriter = pasteboardWriter
    }

    public func open(pathOrURL: String) throws {
        // `--` so paths starting with `-` are not parsed as open(1) flags
        try run("/usr/bin/open", arguments: ["--", pathOrURL])
    }

    public func reveal(path: String) throws {
        try run("/usr/bin/open", arguments: ["-R", "--", path])
    }

    public func copyToPasteboard(text: String) throws {
        try pasteboardWriter(text)
    }

    private func run(_ exe: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CoreError.io("exec \(exe) failed: \(error.localizedDescription)")
        }
        if process.terminationStatus != 0 {
            throw CoreError.io("\(exe) exited \(process.terminationStatus) for \(arguments)")
        }
    }
}

/// Routes object→action names to the executor (and OS helpers).
public enum ModuleRouter {
    public static func perform(
        actionName: String,
        result: SearchResult,
        executor: any ModuleExecuting
    ) throws {
        if try performCore(actionName: actionName, result: result, executor: executor) {
            return
        }
        if try performPower(actionName: actionName, result: result, executor: executor) {
            return
        }
        if case .string(let nested) = result.payload["action"], nested != actionName {
            try perform(actionName: nested, result: result, executor: executor)
            return
        }
        throw CoreError.unknownAction(actionName)
    }

    /// Returns true if handled.
    private static func performCore(
        actionName: String,
        result: SearchResult,
        executor: any ModuleExecuting
    ) throws -> Bool {
        switch actionName {
        case "app.open", "file.open":
            guard let path = result.path, !path.isEmpty else {
                throw CoreError.store("open requires path")
            }
            try executor.open(pathOrURL: path)
            return true
        case "app.reveal", "file.reveal":
            guard let path = result.path, !path.isEmpty else {
                throw CoreError.store("reveal requires path")
            }
            try executor.reveal(path: path)
            return true
        case "file.copyPath":
            guard let path = result.path else { throw CoreError.store("copyPath requires path") }
            try executor.copyToPasteboard(text: path)
            return true
        case "file.trash":
            try trash(result: result, executor: executor)
            return true
        case "file.getInfo":
            try getInfo(result: result, executor: executor)
            return true
        case "file.openWith":
            try openWith(result: result, executor: executor)
            return true
        case "snippet.copy", "snippet.paste", "calc.copy", "calc.paste", "snippet.edit":
            try copyPayloadText(result: result, executor: executor)
            return true
        case "emoji.copy", "emoji.paste":
            // Copy glyph only (not "🚀  rocket") so ↩ is paste-ready.
            try copyEmoji(result: result, executor: executor)
            return true
        case "clipboard.copy", "clipboard.paste", "clipboard.pastePlain":
            try clipboardAction(actionName: actionName, result: result, executor: executor)
            return true
        case "quicklink.open":
            try quicklinkOpen(result: result, executor: executor)
            return true
        case "settings.open":
            if case .string(let key) = result.payload["settingsKey"] {
                try executor.copyToPasteboard(text: key)
            } else {
                try executor.copyToPasteboard(text: result.title)
            }
            return true
        case "command.run":
            try commandRun(result: result, executor: executor)
            return true
        case "process.kill":
            try killProcess(result: result, executor: executor)
            return true
        default:
            return false
        }
    }

    /// Power-module / M2 action names. Stubs stay searchable; handlers must not ↩-fail.
    private static func performPower(
        actionName: String,
        result: SearchResult,
        executor: any ModuleExecuting
    ) throws -> Bool {
        switch actionName {
        case "window.focus":
            try focusProcess(result: result, executor: executor)
        case "screenshot.region":
            try runTool("/usr/sbin/screencapture", ["-i", "-c"], executor: executor, label: "screenshot.region")
        case "screenshot.full":
            try runTool("/usr/sbin/screencapture", ["-c"], executor: executor, label: "screenshot.full")
        case "browser.list":
            try executor.open(pathOrURL: "https://")
        case "terminal.run":
            if case .string(let cmd) = result.payload["command"], !cmd.isEmpty {
                try executor.copyToPasteboard(text: cmd)
            }
            try executor.open(pathOrURL: "/System/Applications/Utilities/Terminal.app")
        case "script.list":
            try openScriptsFolder(executor: executor)
        case "calendar.open":
            try executor.open(pathOrURL: "/System/Applications/Calendar.app")
        case "dict.define":
            if case .string(let word) = result.payload["word"] {
                try executor.open(pathOrURL: "dict://\(word)")
            } else {
                try executor.open(pathOrURL: "/System/Applications/Dictionary.app")
            }
        case "contacts.find":
            try executor.open(pathOrURL: "/System/Applications/Contacts.app")
        case "camera.quick":
            try executor.open(pathOrURL: "/System/Applications/Photo Booth.app")
        case "apps.autoquit":
            try executor.open(pathOrURL: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        case "speech.speak":
            try speechSpeak(result: result, executor: executor)
        case "window.arrange":
            if case .string(let layout) = result.payload["layout"] {
                try executor.copyToPasteboard(text: "window:\(layout)")
            }
        default:
            return false
        }
        return true
    }

    private static func clipboardAction(
        actionName: String,
        result: SearchResult,
        executor: any ModuleExecuting
    ) throws {
        let raw: String
        if case .string(let t) = result.payload["text"] {
            raw = t
        } else {
            raw = result.title
        }
        let text = actionName == "clipboard.pastePlain"
            ? PasteboardPrivacy.asPlainText(raw)
            : raw
        try executor.copyToPasteboard(text: text)
    }

    private static func quicklinkOpen(result: SearchResult, executor: any ModuleExecuting) throws {
        let url: String
        if case .string(let u) = result.payload["url"] {
            url = u
        } else if let path = result.path {
            url = path
        } else {
            throw CoreError.store("quicklink.open requires url")
        }
        try executor.open(pathOrURL: url)
    }

    private static func commandRun(result: SearchResult, executor: any ModuleExecuting) throws {
        if case .string(let u) = result.payload["url"] {
            try SystemEffects.perform(url: u, executor: executor)
            return
        }
        if let path = result.path {
            try SystemEffects.perform(url: path, executor: executor)
            return
        }
        if case .string(let nested) = result.payload["action"] {
            try perform(actionName: nested, result: result, executor: executor)
            return
        }
        throw CoreError.store("command.run requires url/path")
    }

    private static func copyPayloadText(result: SearchResult, executor: any ModuleExecuting) throws {
        let text: String
        if case .string(let body) = result.payload["body"] {
            text = body
        } else if case .string(let t) = result.payload["text"] {
            text = t
        } else if result.kind == .calculation {
            text = result.title
        } else {
            text = result.title
        }
        try executor.copyToPasteboard(text: text)
    }

    /// Prefer payload `emoji` / `text`; never the display title with name.
    private static func copyEmoji(result: SearchResult, executor: any ModuleExecuting) throws {
        let glyph: String
        if case .string(let e) = result.payload["emoji"], !e.isEmpty {
            glyph = e
        } else if case .string(let t) = result.payload["text"], !t.isEmpty {
            glyph = t
        } else if result.id.hasPrefix("emoji:") {
            glyph = String(result.id.dropFirst("emoji:".count))
        } else {
            // First token of "🚀  rocket" style titles
            glyph = result.title.split(separator: " ").first.map(String.init) ?? result.title
        }
        try executor.copyToPasteboard(text: glyph)
    }

    private static func trash(result: SearchResult, executor: any ModuleExecuting) throws {
        guard let path = result.path, !path.isEmpty else {
            throw CoreError.store("trash requires path")
        }
        if let recording = executor as? RecordingModuleExecutor {
            recording.recordTrash(path: path)
            return
        }
        let url = URL(fileURLWithPath: path)
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            throw CoreError.io("trash failed: \(error.localizedDescription)")
        }
    }

    private static func getInfo(result: SearchResult, executor: any ModuleExecuting) throws {
        guard let path = result.path, !path.isEmpty else {
            throw CoreError.store("getInfo requires path")
        }
        try executor.reveal(path: path)
        if executor is RecordingModuleExecutor { return }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\" to open information window of (POSIX file \"\(escaped)\" as alias)"
        try runTool("/usr/bin/osascript", ["-e", script], executor: executor, label: "getInfo")
    }

    private static func openWith(result: SearchResult, executor: any ModuleExecuting) throws {
        guard let path = result.path, !path.isEmpty else {
            throw CoreError.store("openWith requires path")
        }
        try executor.copyToPasteboard(text: path)
        try executor.open(pathOrURL: path)
    }

    private static func killProcess(result: SearchResult, executor: any ModuleExecuting) throws {
        let pid: Int32
        if case .string(let s) = result.payload["pid"], let p = Int32(s) {
            pid = p
        } else if result.id.hasPrefix("proc:"), let p = Int32(result.id.dropFirst(5)) {
            pid = p
        } else {
            throw CoreError.store("process.kill requires pid")
        }
        if let recording = executor as? RecordingModuleExecutor {
            recording.recordKill(pid: pid)
            return
        }
        guard ProcessControl.kill(pid: pid) else {
            throw CoreError.io("kill(\(pid)) failed")
        }
    }

    private static func focusProcess(result: SearchResult, executor: any ModuleExecuting) throws {
        let pid: Int32?
        if case .string(let s) = result.payload["pid"] {
            pid = Int32(s)
        } else if result.id.hasPrefix("alttab:") {
            pid = Int32(result.id.dropFirst(7))
        } else {
            pid = nil
        }
        if let pid, let recording = executor as? RecordingModuleExecutor {
            recording.recordOp("focus", value: "\(pid)")
            return
        }
        if let pid {
            let script = "tell application \"System Events\" to set frontmost of (first process whose unix id is \(pid)) to true"
            try runTool("/usr/bin/osascript", ["-e", script], executor: executor, label: "window.focus")
        } else {
            try executor.open(pathOrURL: result.title)
        }
    }

    private static func openScriptsFolder(executor: any ModuleExecuting) throws {
        let scripts = (try? SummonDatabase.defaultContainerURL())?
            .appendingPathComponent("Scripts", isDirectory: true)
        if let scripts {
            try? FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            try executor.open(pathOrURL: scripts.path)
        } else {
            try executor.open(pathOrURL: NSHomeDirectory())
        }
    }

    private static func speechSpeak(result: SearchResult, executor: any ModuleExecuting) throws {
        let text: String
        if case .string(let t) = result.payload["text"], !t.isEmpty {
            text = t
        } else {
            text = result.subtitle ?? result.title
        }
        try runTool("/usr/bin/say", [text], executor: executor, label: "speech.speak")
    }

    private static func runTool(
        _ exe: String,
        _ args: [String],
        executor: any ModuleExecuting,
        label: String
    ) throws {
        if let recording = executor as? RecordingModuleExecutor {
            recording.recordOp(label, value: args.joined(separator: " "))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CoreError.io("\(label) failed: \(error.localizedDescription)")
        }
        if process.terminationStatus != 0 {
            throw CoreError.io("\(label) exited \(process.terminationStatus)")
        }
    }
}
