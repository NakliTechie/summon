import Foundation

/// Kill / quit helpers (RC-14). Destructive — agent propose-only.
public struct ProcessInfoRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let pid: Int32

    public init(name: String, pid: Int32) {
        self.id = "proc:\(pid)"
        self.name = name
        self.pid = pid
    }
}

public enum ProcessControl {
    public static func runningApps() -> [ProcessInfoRow] {
        // Headless: parse `ps` (no AppKit). Split on *last* whitespace so names with spaces survive.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            var rows: [ProcessInfoRow] = []
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let space = trimmed.firstIndex(where: { $0.isWhitespace }) else { continue }
                let pidStr = String(trimmed[..<space]).trimmingCharacters(in: .whitespaces)
                let name = String(trimmed[trimmed.index(after: space)...])
                    .trimmingCharacters(in: .whitespaces)
                guard let pid = Int32(pidStr), !name.isEmpty else { continue }
                rows.append(ProcessInfoRow(name: name, pid: pid))
            }
            return rows
        } catch {
            return []
        }
    }

    public static func search(query: String, limit: Int = 20) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefix = "kill "
        let nameQ: String
        if q.hasPrefix(prefix) {
            nameQ = String(q.dropFirst(prefix.count))
        } else if q.hasPrefix("quit ") {
            nameQ = String(q.dropFirst(5))
        } else {
            return []
        }
        guard !nameQ.isEmpty else { return [] }
        return runningApps()
            .filter { $0.name.lowercased().contains(nameQ) }
            .prefix(limit)
            .map { p in
                SearchResult(
                    id: p.id,
                    title: "Kill \(p.name)",
                    subtitle: "pid \(p.pid)",
                    kind: .command,
                    score: 0.7,
                    payload: [
                        "pid": .string("\(p.pid)"),
                        "destructive": .bool(true),
                        "action": .string("process.kill"),
                    ]
                )
            }
    }

    /// Signal a process. Returns false if kill fails.
    @discardableResult
    public static func kill(pid: Int32, signal: Int32 = 15) -> Bool {
        Darwin.kill(pid, signal) == 0
    }
}
