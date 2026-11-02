import Foundation

/// A local debug log of every use, one JSON object per line, in
/// `~/Library/Logs/Summon/usage.jsonl`. It exists so a stall or a wrong answer
/// during dogfooding can be read back step by step with timings. Nothing leaves
/// the Mac: this is a file the user owns, not telemetry.
///
/// Opt-in (see `isEnabled`).
///
/// It records launcher queries, AI and web prompts and answers, and the names of
/// the fields Smart Paste filled. It never records clipboard contents (a clipboard
/// row logs its kind) and never a value Smart Paste filled, so it cannot hold a
/// secure field's value either.
public enum UsageLog {
    /// Off by default. On with `defaults write tech.nakli.Summon UsageLog -bool true`, or with
    /// `SUMMON_USAGE_LOG=1` (or a file path) in the environment; `SUMMON_USAGE_LOG=0` forces it
    /// off. Always off under XCTest so test runs never write the owner's log.
    public static let isEnabled: Bool = enabled(
        environment: ProcessInfo.processInfo.environment,
        // Summon's own domain only: `UserDefaults.bool(forKey:)` also reads the global domain.
        defaultsSetting: UserDefaults.standard.persistentDomain(forName: "tech.nakli.Summon")?["UsageLog"] as? Bool ?? false,
        underTest: NSClassFromString("XCTestCase") != nil
    )

    static func enabled(environment: [String: String], defaultsSetting: Bool, underTest: Bool) -> Bool {
        if underTest || environment["XCTestConfigurationFilePath"] != nil { return false }
        switch environment["SUMMON_USAGE_LOG"] {
        case "0": return false
        case let value? where !value.isEmpty: return true
        default: return defaultsSetting
        }
    }

    public static let fileURL: URL = {
        if let path = ProcessInfo.processInfo.environment["SUMMON_USAGE_LOG"], path.count > 1 {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Summon/usage.jsonl")
    }()

    /// Past this size the file moves to `usage.1.jsonl` (one old file kept).
    static let rotateBytes: UInt64 = 20_000_000
    /// Long text (an answer, a prompt) is cut to this many characters.
    static let maxFieldLength = 4_000

    private static let queue = DispatchQueue(label: "tech.nakli.Summon.usagelog")

    /// Lines are written on a background queue; a short-lived process (the CLI) would
    /// exit before they land, so the queue drains once at exit.
    private static let flushAtExit: Void = {
        atexit { UsageLog.queue.sync {} }
    }()
    private static let process = ProcessInfo.processInfo.processName
    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "Asia/Kolkata")
        return formatter
    }()

    /// Append one event. Never throws and never blocks the caller on disk.
    public static func record(_ event: String, _ fields: [String: String] = [:]) {
        guard isEnabled else { return }
        _ = flushAtExit
        let now = Date()
        queue.async { write(event: event, fields: fields, at: now) }
    }

    /// Start a timed step; `end` records `<event>.done` (or `.failed`) with `ms`.
    public static func span(_ event: String, _ fields: [String: String] = [:]) -> Span {
        let id = String(UUID().uuidString.prefix(8))
        record(event, fields.merging(["span": id]) { first, _ in first })
        return Span(event: event, id: id, started: DispatchTime.now())
    }

    /// One timed step. Its start and end lines share `span`, so a start with no
    /// end in the log is a step that never finished.
    public struct Span: Sendable {
        let event: String
        let id: String
        let started: DispatchTime

        public var elapsedMs: Int {
            Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
        }

        public func end(_ fields: [String: String] = [:]) {
            UsageLog.record(event + ".done", fields.merging(["ms": String(elapsedMs), "span": id]) { first, _ in first })
        }

        public func fail(_ error: Error, _ fields: [String: String] = [:]) {
            UsageLog.record(event + ".failed", fields.merging([
                "ms": String(elapsedMs), "error": String(describing: error), "span": id,
            ]) { first, _ in first })
        }
    }

    /// A result's title for the log. A clipboard row's title is clipboard text, which
    /// the log must not hold, so it logs the kind instead.
    public static func loggableTitle(_ title: String, kind: SearchResult.Kind) -> String {
        kind == .clipboard ? "(clipboard item)" : title
    }

    /// Smart-paste fills for the log: field names only, never a value. A value comes from the
    /// copied text, and "applied" can be wrong (the keystroke fallback reports success without
    /// reading the field back), so no value is written here at all.
    public static func smartPasteSummary(fills: [SmartPasteFill], labels: [String: String], applied: Set<String>?) -> String {
        fills.map { fill in
            let label = labels[fill.fieldID] ?? fill.fieldID
            guard let applied else { return label }
            return applied.contains(fill.fieldID) ? "\(label) (applied)" : "\(label) (not applied)"
        }.joined(separator: " | ")
    }

    /// The case name of an action, without its payload (which can hold user text).
    public static func name(of action: CoreAction) -> String {
        String(String(describing: action).prefix { $0 != "(" })
    }

    private static func write(event: String, fields: [String: String], at date: Date) {
        var object: [String: String] = fields.mapValues { value in
            value.count > maxFieldLength ? String(value.prefix(maxFieldLength)) + "…" : value
        }
        object["t"] = timestamp.string(from: date)
        object["event"] = event
        object["process"] = process
        guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfLarge(manager: manager, directory: directory)
        // One O_APPEND write per line: the app and the CLI can both log at once, and an
        // append never overwrites another process's line (seek-then-write could). Owner-only.
        // A shared lock keeps a write out of the window where rotation renames the file.
        let lock = open(fileURL.path + ".lock", O_RDWR | O_CREAT, 0o600)
        guard lock >= 0, lockRetrying(lock, LOCK_SH) else {
            if lock >= 0 { close(lock) }
            return // a debug log may drop a line; it must not race a rotation
        }
        defer { flock(lock, LOCK_UN); close(lock) }
        let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        line.withUnsafeBytes { bytes in
            guard var next = bytes.baseAddress else { return }
            var left = bytes.count
            while left > 0 { // finish a short write; give up on a real error
                let wrote = Darwin.write(descriptor, next, left)
                if wrote < 0 { if errno == EINTR { continue } else { return } }
                left -= wrote
                next += wrote
            }
        }
    }

    /// Past `rotateBytes` the file moves to `usage.1.jsonl` (one old file kept). The app and
    /// the CLI can both see a large file, so rotation runs under a lock file and re-checks the
    /// size inside it: the second process finds a small file and leaves the archive alone.
    private static func rotateIfLarge(manager: FileManager, directory: URL) {
        func size() -> UInt64 { (try? manager.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64 ?? 0 }
        guard size() > rotateBytes else { return }
        let lock = open(fileURL.path + ".lock", O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { return }
        defer { close(lock) }
        guard lockRetrying(lock, LOCK_EX) else { return }
        defer { flock(lock, LOCK_UN) }
        guard size() > rotateBytes else { return }
        let old = directory.appendingPathComponent(
            fileURL.deletingPathExtension().lastPathComponent + ".1." + fileURL.pathExtension
        )
        rename(fileURL.path, old.path) // replaces an earlier archive atomically
    }

    /// `flock`, retried when a signal interrupts it.
    private static func lockRetrying(_ descriptor: Int32, _ operation: Int32) -> Bool {
        while flock(descriptor, operation) != 0 {
            guard errno == EINTR else { return false }
        }
        return true
    }
}
