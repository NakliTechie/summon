import Foundation

/// A local debug log of every use, one JSON object per line, in
/// `~/Library/Logs/Summon/usage.jsonl`. It exists so a stall or a wrong answer
/// during dogfooding can be read back step by step with timings. Nothing leaves
/// the Mac: this is a file the user owns, not telemetry.
///
/// On while the owner dogfoods (decided 2026-11-02); `isEnabled` goes false for a
/// public release. Off under XCTest so test runs never write the user's log.
/// `SUMMON_USAGE_LOG=0` turns it off; `SUMMON_USAGE_LOG=<path>` writes elsewhere.
///
/// It records launcher queries, AI and web prompts and answers, and smart-paste
/// fills. It never records clipboard contents beyond what smart paste wrote into
/// a field, and never a secure field.
public enum UsageLog {
    public static let isEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil { return false }
        return env["SUMMON_USAGE_LOG"] != "0"
    }()

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

    /// Smart-paste fills for the log. A proposal names fields only: its values come from
    /// the copied text and nothing has been written yet. After a fill, only the fields
    /// that accepted their value are listed with it (a secure field is never filled).
    public static func smartPasteSummary(fills: [SmartPasteFill], labels: [String: String], applied: Set<String>?) -> String {
        fills.map { fill in
            let label = labels[fill.fieldID] ?? fill.fieldID
            guard let applied else { return label }
            return applied.contains(fill.fieldID) ? "\(label)=\(fill.value)" : "\(label) (not applied)"
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
        if let size = (try? manager.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64, size > rotateBytes {
            let old = directory.appendingPathComponent(
                fileURL.deletingPathExtension().lastPathComponent + ".1." + fileURL.pathExtension
            )
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: fileURL, to: old)
        }
        // One O_APPEND write per line: the app and the CLI can both log at once, and an
        // append never overwrites another process's line (seek-then-write could). Owner-only.
        let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        line.withUnsafeBytes { _ = Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }
}
