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

/// Screenshot + annotation stub (RC-32) — stages a path/action, no capture in core.
public enum ScreenshotModule {
    public static func search(query: String) -> [SearchResult] {
        let q = query.lowercased()
        guard q == "screenshot" || q.hasPrefix("screenshot ") || q == "capture" else { return [] }
        return [
            SearchResult(
                id: "shot:region",
                title: "Screenshot region",
                subtitle: "annotate · pin · history",
                kind: .command,
                score: 0.9,
                payload: ["action": .string("screenshot.region")]
            ),
            SearchResult(
                id: "shot:full",
                title: "Screenshot display",
                subtitle: "full screen",
                kind: .command,
                score: 0.85,
                payload: ["action": .string("screenshot.full")]
            ),
        ]
    }
}

/// Browser tabs/history stub (RC-33).
public enum BrowserModule {
    public static func search(query: String) -> [SearchResult] {
        let q = query.lowercased()
        guard q.hasPrefix("tab ") || q.hasPrefix("bookmark ") || q == "tabs" else { return [] }
        return [
            SearchResult(
                id: "browser:stub",
                title: "Browser integration",
                subtitle: "tabs/history/bookmarks — install browser bridge",
                kind: .command,
                score: 0.5,
                payload: ["action": .string("browser.list")]
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
    public init(enumerator: any CalendarEnumerating = FakeCalendarEnumerator()) {
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
                    title: cmd.isEmpty ? "Open Terminal" : "Run: \(cmd)",
                    subtitle: "staged shell — never auto-run",
                    kind: .command,
                    score: 0.8,
                    payload: ["action": .string("terminal.run"), "command": .string(cmd), "staged": .bool(true)]
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
                subtitle: "system widget",
                kind: .command,
                score: 0.4
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

/// App hotkeys config (RC-10) — storage only until Carbon registration expands.
public struct AppHotkeyBinding: Sendable, Hashable, Codable, Equatable {
    public let appPath: String
    public let keyCode: UInt32
    public let modifiers: UInt32
    public init(appPath: String, keyCode: UInt32, modifiers: UInt32) {
        self.appPath = appPath
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Snippet expansion detector (RC-07) — expansion engine registers later.
public enum SnippetExpansion {
    public static func match(typed: String, snippets: [Snippet]) -> Snippet? {
        snippets.first { snip in
            guard let kw = snip.keyword, !kw.isEmpty else { return false }
            return typed.hasSuffix(kw)
        }
    }
}

/// Contacts / dictionary stubs (SP-08/09).
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
        if q.hasPrefix("contact ") {
            let name = String(query.dropFirst(8))
            return [
                SearchResult(
                    id: "contact:\(name)",
                    title: name,
                    subtitle: "contacts — EventKit/Contacts consent required",
                    kind: .command,
                    score: 0.65,
                    payload: ["action": .string("contacts.find"), "name": .string(name)]
                ),
            ]
        }
        return []
    }
}

/// Quick camera / auto-quit / read-aloud (RC-61–63).
public enum MiscPowerModules {
    public static func search(query: String) -> [SearchResult] {
        let q = query.lowercased()
        var out: [SearchResult] = []
        if q == "camera" || q.hasPrefix("camera ") {
            out.append(SearchResult(
                id: "camera:quick",
                title: "Quick camera",
                subtitle: "capture still",
                kind: .command,
                score: 0.7,
                payload: ["action": .string("camera.quick")]
            ))
        }
        if q.hasPrefix("autoquit ") || q == "auto-quit" {
            out.append(SearchResult(
                id: "autoquit",
                title: "Auto-quit idle apps",
                subtitle: "configure rules",
                kind: .command,
                score: 0.6,
                payload: ["action": .string("apps.autoquit")]
            ))
        }
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

/// Navigation bindings (RC-64).
public struct NavigationBindings: Sendable, Hashable, Codable, Equatable {
    public var upKey: String
    public var downKey: String
    public var confirmKey: String
    public var actionsKey: String
    public var dismissKey: String

    public static let `default` = NavigationBindings(
        upKey: "up",
        downKey: "down",
        confirmKey: "return",
        actionsKey: "tab",
        dismissKey: "escape"
    )
}

/// Window Spaces multi-display (RC-56 / F15).
public enum WindowSpaces {
    public static func layoutsForMultiDisplay() -> [WindowLayout] {
        WindowLayout.allCases
    }
}
