import Foundation

/// Executes object→action module effects (open, reveal, copy). Headless-safe via `/usr/bin/open`.
public protocol ModuleExecuting: Sendable {
    func open(pathOrURL: String) throws
    func reveal(path: String) throws
    func copyToPasteboard(text: String) throws
    func copyClipboardItem(_ item: ClipboardItem, asPlainText: Bool) throws
    func showAppDestination(_ destination: AppDestination) throws
    func arrangeWindow(layout: WindowLayout, gap: CGFloat) throws
    func installExtension(sourcePath: String) throws
    func setExtensionGrant(extensionID: String, entitlement: String, granted: Bool) throws
}

public extension ModuleExecuting {
    func copyClipboardItem(_ item: ClipboardItem, asPlainText: Bool) throws {
        try copyToPasteboard(text: item.plainText)
    }

    func arrangeWindow(layout: WindowLayout, gap: CGFloat) throws {
        throw CoreError.store("window arranger not configured")
    }

    func showAppDestination(_ destination: AppDestination) throws {
        throw CoreError.store("app destination \(destination.rawValue) not configured")
    }

    func installExtension(sourcePath: String) throws {
        throw CoreError.store("extension installer not configured")
    }

    func setExtensionGrant(extensionID: String, entitlement: String, granted: Bool) throws {
        throw CoreError.store("extension grant store not configured")
    }
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
    public private(set) var copiedClipboardItems: [ClipboardItem] = []

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

    public func copyClipboardItem(_ item: ClipboardItem, asPlainText: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        copiedClipboardItems.append(item)
        pasteboard = item.plainText
        calls.append(Call(op: asPlainText ? "copyClipboardPlain" : "copyClipboard", value: item.id))
    }

    public func showAppDestination(_ destination: AppDestination) throws {
        recordOp("app.navigate", value: destination.rawValue)
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

    public func arrangeWindow(layout: WindowLayout, gap: CGFloat) throws {
        recordOp("window.arrange", value: "\(layout.rawValue):\(gap)")
    }

    public func installExtension(sourcePath: String) throws {
        recordOp("extension.install", value: sourcePath)
    }

    public func setExtensionGrant(extensionID: String, entitlement: String, granted: Bool) throws {
        recordOp(
            granted ? "extension.grant" : "extension.revoke",
            value: "\(extensionID):\(entitlement)"
        )
    }
}

/// Production executor: `/usr/bin/open` and a pasteboard sink (injected for tests).
public struct ProcessModuleExecutor: ModuleExecuting, Sendable {
    public var pasteboardWriter: @Sendable (String) throws -> Void
    public var clipboardWriter: (@Sendable (ClipboardItem, Bool) throws -> Void)?
    public var destinationOpener: (@Sendable (AppDestination) throws -> Void)?
    public var windowArranger: (@Sendable (WindowLayout, CGFloat) throws -> Void)?
    public var extensionInstaller: (@Sendable (String) throws -> Void)?
    public var extensionGrantSetter: (@Sendable (String, String, Bool) throws -> Void)?

    public init(
        pasteboardWriter: @escaping @Sendable (String) throws -> Void = { _ in
            throw CoreError.io("pasteboard writer not configured")
        },
        clipboardWriter: (@Sendable (ClipboardItem, Bool) throws -> Void)? = nil,
        destinationOpener: (@Sendable (AppDestination) throws -> Void)? = nil,
        windowArranger: (@Sendable (WindowLayout, CGFloat) throws -> Void)? = nil,
        extensionInstaller: (@Sendable (String) throws -> Void)? = nil,
        extensionGrantSetter: (@Sendable (String, String, Bool) throws -> Void)? = nil
    ) {
        self.pasteboardWriter = pasteboardWriter
        self.clipboardWriter = clipboardWriter
        self.destinationOpener = destinationOpener
        self.windowArranger = windowArranger
        self.extensionInstaller = extensionInstaller
        self.extensionGrantSetter = extensionGrantSetter
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

    public func copyClipboardItem(_ item: ClipboardItem, asPlainText: Bool) throws {
        if let clipboardWriter {
            try clipboardWriter(item, asPlainText)
        } else {
            try pasteboardWriter(item.plainText)
        }
    }

    public func showAppDestination(_ destination: AppDestination) throws {
        guard let destinationOpener else {
            throw CoreError.store("app destination \(destination.rawValue) not configured")
        }
        try destinationOpener(destination)
    }

    public func arrangeWindow(layout: WindowLayout, gap: CGFloat) throws {
        guard let windowArranger else {
            throw CoreError.store("window arranger not configured")
        }
        try windowArranger(layout, gap)
    }

    public func installExtension(sourcePath: String) throws {
        guard let extensionInstaller else {
            throw CoreError.store("extension installer not configured")
        }
        try extensionInstaller(sourcePath)
    }

    public func setExtensionGrant(extensionID: String, entitlement: String, granted: Bool) throws {
        guard let extensionGrantSetter else {
            throw CoreError.store("extension grant store not configured")
        }
        try extensionGrantSetter(extensionID, entitlement, granted)
    }

    private func run(_ exe: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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
        case "snippet.copy", "calc.copy":
            try copyPayloadText(result: result, executor: executor)
            return true
        case "emoji.copy":
            // Copy glyph only (not "🚀  rocket") so ↩ is paste-ready.
            try copyEmoji(result: result, executor: executor)
            return true
        case "clipboard.copy", "clipboard.copyPlain":
            try clipboardAction(actionName: actionName, result: result, executor: executor)
            return true
        case "quicklink.open":
            try quicklinkOpen(result: result, executor: executor)
            return true
        case "settings.open":
            let raw: String
            if case .string(let destination) = result.payload["destination"] {
                raw = destination
            } else if case .string(let key) = result.payload["settingsKey"] {
                raw = SettingsCatalog.destination(for: key).rawValue
            } else {
                raw = AppDestination.preferencesGeneral.rawValue
            }
            guard let destination = AppDestination(rawValue: raw) else {
                throw CoreError.store("settings.open requires a valid destination")
            }
            try executor.showAppDestination(destination)
            return true
        case "app.navigate":
            guard case .string(let raw) = result.payload["destination"],
                  let destination = AppDestination(rawValue: raw) else {
                throw CoreError.store("app.navigate requires a valid destination")
            }
            try executor.showAppDestination(destination)
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

    /// Power-module / M2 action names exposed by live search rows.
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
                try executor.open(pathOrURL: dictionaryURL(for: word))
            } else {
                try executor.open(pathOrURL: "/System/Applications/Dictionary.app")
            }
        case "speech.speak":
            try speechSpeak(result: result, executor: executor)
        case "window.arrange":
            guard case .string(let rawLayout) = result.payload["layout"],
                  let layout = WindowLayout(rawValue: rawLayout) else {
                throw CoreError.store("window.arrange requires a valid layout")
            }
            let gap = CGFloat(result.payload["gap"]?.numberValue ?? 8)
            try executor.arrangeWindow(layout: layout, gap: gap)
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
        let sourceFlavor = result.payload["flavor"]?.stringValue
        let text = actionName == "clipboard.copyPlain"
            ? PasteboardPrivacy.asPlainText(raw, sourceFlavor: sourceFlavor)
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
        let script = """
        on run argv
            set targetPath to item 1 of argv
            tell application "Finder" to open information window of (POSIX file targetPath as alias)
        end run
        """
        try runTool(
            "/usr/bin/osascript",
            ["-e", script, "--", path],
            executor: executor,
            label: "getInfo"
        )
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
        try runTool("/usr/bin/say", ["--", text], executor: executor, label: "speech.speak")
    }

    private static func dictionaryURL(for word: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        let encoded = word.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "dict://\(encoded)"
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
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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
