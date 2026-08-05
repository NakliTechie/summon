import Foundation
import Darwin

// MARK: - Phase F power modules (headless seams + search hits)

/// Alt-tab switcher model (RC-31) — live AX later; list apps for now.
public enum AltTabModule {
    public static func candidates(limit: Int = 20) -> [SearchResult] {
        ProcessControl.runningApps()
            .prefix(limit)
            .map { p in
                SearchResult(
                    id: "alttab:\(p.pid)",
                    title: p.name,
                    subtitle: "switch · pid \(p.pid)",
                    kind: .command,
                    score: 0.6,
                    payload: ["pid": .string("\(p.pid)"), "action": .string("window.focus")]
                )
            }
    }

    public static func search(query: String) -> [SearchResult] {
        let q = query.lowercased()
        guard q.hasPrefix("switch ") || q.hasPrefix("tab ") || q == "switch" || q == "alttab" else {
            return []
        }
        let nameQ: String
        if q.hasPrefix("switch ") {
            nameQ = String(q.dropFirst(7))
        } else if q.hasPrefix("tab ") {
            nameQ = String(q.dropFirst(4))
        } else {
            nameQ = ""
        }
        let all = candidates()
        if nameQ.isEmpty { return Array(all.prefix(15)) }
        return all.filter { $0.title.lowercased().contains(nameQ) }
    }
}

/// Screenshot capture actions (RC-32). Annotation and history are not exposed yet.
public enum ScreenshotModule {
    public static func search(query: String) -> [SearchResult] {
        let q = query.lowercased()
        guard q == "screenshot" || q.hasPrefix("screenshot ") || q == "capture" else { return [] }
        return [
            SearchResult(
                id: "shot:region",
                title: "Screenshot region",
                subtitle: "select a region · copy to clipboard",
                kind: .command,
                score: 0.9,
                payload: ["action": .string("screenshot.region")]
            ),
            SearchResult(
                id: "shot:full",
                title: "Screenshot display",
                subtitle: "copy display screenshot to clipboard",
                kind: .command,
                score: 0.85,
                payload: ["action": .string("screenshot.full")]
            ),
        ]
    }
}

/// Calendar EventKit surface (SP-10, RC-34) — models only until EventKit live.
public struct CalendarEventDescriptor: Sendable, Hashable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date

    public init(id: String = UUID().uuidString, title: String, start: Date, end: Date) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
    }
}

public protocol CalendarEnumerating: Sendable {
    func events(matching query: String) throws -> [CalendarEventDescriptor]
}

public struct FakeCalendarEnumerator: CalendarEnumerating, Sendable {
    public var events: [CalendarEventDescriptor]
    public init(events: [CalendarEventDescriptor] = []) { self.events = events }
    public func events(matching query: String) throws -> [CalendarEventDescriptor] {
        let q = query.lowercased()
        if q.isEmpty { return events }
        return events.filter { $0.title.lowercased().contains(q) }
    }
}

public struct CalendarSurface: Sendable {
    public var enumerator: any CalendarEnumerating
    public init(enumerator: any CalendarEnumerating) {
        self.enumerator = enumerator
    }
    public func search(query: String) throws -> [SearchResult] {
        let q = query.lowercased()
        let free: String
        if q.hasPrefix("cal ") {
            free = String(query.dropFirst(4))
        } else if q.hasPrefix("calendar ") {
            free = String(query.dropFirst(9))
        } else if q == "cal" || q == "calendar" {
            free = ""
        } else {
            return []
        }
        return try enumerator.events(matching: free).map {
            SearchResult(
                id: "cal:\($0.id)",
                title: $0.title,
                subtitle: "event",
                kind: .command,
                score: 0.75,
                payload: ["action": .string("calendar.open"), "eventID": .string($0.id)]
            )
        }
    }
}

/// Terminal / custom scripts (RC-35–36).
public enum TerminalModule {
    public static func search(query: String) -> [SearchResult] {
        let q = query.lowercased()
        if q.hasPrefix("> ") || q.hasPrefix("shell ") || q.hasPrefix("term ") {
            let cmd = query.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            return [
                SearchResult(
                    id: "term:\(cmd)",
                    title: cmd.isEmpty ? "Open Terminal" : "Open Terminal with command copied",
                    subtitle: cmd.isEmpty ? "open Terminal.app" : "\(cmd) · Summon never executes it",
                    kind: .command,
                    score: 0.8,
                    payload: ["action": .string("terminal.run"), "command": .string(cmd)]
                ),
            ]
        }
        if q.hasPrefix("script ") {
            return [
                SearchResult(
                    id: "script:list",
                    title: "Custom scripts",
                    subtitle: "user scripts folder",
                    kind: .command,
                    score: 0.7,
                    payload: ["action": .string("script.list")]
                ),
            ]
        }
        return []
    }
}

/// System widgets (RC-37).
public enum SystemWidgets {
    public static func snapshot() -> [SearchResult] {
        var mem = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &mem) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let rss: String
        if kr == KERN_SUCCESS {
            rss = String(format: "%.1f MB", Double(mem.resident_size) / 1_048_576)
        } else {
            rss = "n/a"
        }
        return [
            SearchResult(
                id: "widget:mem",
                title: "Memory (Summon): \(rss)",
                subtitle: "system widget · Return copies value",
                kind: .command,
                score: 0.4,
                payload: [
                    "text": .string(rss),
                    "action": .string("snippet.copy"),
                ]
            ),
        ]
    }

    public static func search(query: String) -> [SearchResult] {
        let q = query.lowercased()
        guard q == "cpu" || q == "mem" || q == "memory" || q == "widgets" || q.hasPrefix("sysmon") else {
            return []
        }
        return snapshot()
    }
}

/// Snippet expansion detector (RC-07) — used by SearchService for exact keyword hits.
public enum SnippetExpansion {
    public static func match(typed: String, snippets: [Snippet]) -> Snippet? {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // Exact keyword match first, then suffix (typing-expansion style)
        if let exact = snippets.first(where: { ($0.keyword ?? "") == t }) {
            return exact
        }
        return snippets.first { snip in
            guard let kw = snip.keyword, !kw.isEmpty else { return false }
            return t.hasSuffix(kw)
        }
    }

    public static func searchResult(for snippet: Snippet) -> SearchResult {
        SearchResult(
            id: "snippet:\(snippet.id)",
            title: snippet.name,
            subtitle: snippet.keyword.map { "keyword · \($0)" } ?? "snippet",
            kind: .snippet,
            score: 0.98,
            payload: [
                "snippetID": .string(snippet.id),
                "body": .string(snippet.body),
                "text": .string(snippet.body),
                "action": .string("snippet.copy"),
            ]
        )
    }
}

/// Dictionary lookup (SP-09). Contacts remain hidden until a consented adapter exists.
public enum ContactsDictionary {
    public static func search(query: String) -> [SearchResult] {
        let q = query.lowercased()
        if q.hasPrefix("define ") {
            let word = String(query.dropFirst(7))
            return [
                SearchResult(
                    id: "dict:\(word)",
                    title: word,
                    subtitle: "dictionary — open Dictionary.app",
                    kind: .command,
                    score: 0.7,
                    payload: ["action": .string("dict.define"), "word": .string(word)]
                ),
            ]
        }
        return []
    }
}

/// Read-aloud (RC-63). Camera and auto-quit stay hidden until their live actions exist.
public enum MiscPowerModules {
    public static func search(query: String) -> [SearchResult] {
        let q = query.lowercased()
        var out: [SearchResult] = []
        if q.hasPrefix("speak ") || q.hasPrefix("say ") {
            let text = query.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            out.append(SearchResult(
                id: "speak",
                title: "Read aloud",
                subtitle: text.isEmpty ? "AVSpeech" : text,
                kind: .command,
                score: 0.75,
                payload: ["action": .string("speech.speak"), "text": .string(text)]
            ))
        }
        return out
    }
}
