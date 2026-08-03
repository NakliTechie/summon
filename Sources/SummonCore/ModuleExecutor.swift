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
}

/// Production executor: `/usr/bin/open` and a pasteboard sink (injected for tests).
public struct ProcessModuleExecutor: ModuleExecuting, Sendable {
    public var pasteboardWriter: @Sendable (String) throws -> Void

    public init(pasteboardWriter: @escaping @Sendable (String) throws -> Void = { _ in
        // Default no-op in pure Foundation; SummonUI wires NSPasteboard.
        throw CoreError.io("pasteboard writer not configured")
    }) {
        self.pasteboardWriter = pasteboardWriter
    }

    public func open(pathOrURL: String) throws {
        try run("/usr/bin/open", arguments: [pathOrURL])
    }

    public func reveal(path: String) throws {
        try run("/usr/bin/open", arguments: ["-R", path])
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

/// Routes object→action names to the executor.
public enum ModuleRouter {
    public static func perform(
        actionName: String,
        result: SearchResult,
        executor: any ModuleExecuting
    ) throws {
        switch actionName {
        case "app.open", "file.open":
            guard let path = result.path, !path.isEmpty else {
                throw CoreError.store("open requires path")
            }
            try executor.open(pathOrURL: path)
        case "app.reveal", "file.reveal":
            guard let path = result.path, !path.isEmpty else {
                throw CoreError.store("reveal requires path")
            }
            try executor.reveal(path: path)
        case "file.copyPath":
            guard let path = result.path else {
                throw CoreError.store("copyPath requires path")
            }
            try executor.copyToPasteboard(text: path)
        case "snippet.copy", "snippet.paste", "calc.copy", "calc.paste":
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
        case "clipboard.copy", "clipboard.paste", "clipboard.pastePlain":
            let raw: String
            if case .string(let t) = result.payload["text"] {
                raw = t
            } else {
                raw = result.title
            }
            let text = actionName == "clipboard.pastePlain"
                ? raw.precomposedStringWithCanonicalMapping
                : raw
            try executor.copyToPasteboard(text: text)
        case "quicklink.open":
            let url: String
            if case .string(let u) = result.payload["url"] {
                url = u
            } else if let path = result.path {
                url = path
            } else {
                throw CoreError.store("quicklink.open requires url")
            }
            try executor.open(pathOrURL: url)
        case "command.run":
            let url: String
            if case .string(let u) = result.payload["url"] {
                url = u
            } else if let path = result.path {
                url = path
            } else {
                throw CoreError.store("command.run requires url/path")
            }
            try SystemEffects.perform(url: url, executor: executor)
        default:
            throw CoreError.unknownAction(actionName)
        }
    }
}
