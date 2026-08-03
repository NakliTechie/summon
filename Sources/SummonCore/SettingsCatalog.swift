import Foundation

/// Minimal settings surface as launcher results (RC-16). Full prefs window later.
public enum SettingsCatalog {
    public static let keys: [(key: String, title: String, subtitle: String)] = [
        ("agent.socket.enabled", "Agent socket", "Default ON — UNIX socket for agents"),
        ("search.fts.enabled", "Content search (S2)", "FTS5 index — consent first"),
        ("web.search.enabled", "Web search (W1)", "User SearXNG only — default OFF"),
        ("web.search.baseURL", "SearXNG base URL", "Preset http://127.0.0.1:8080"),
        ("launchAtLogin", "Launch at login", "Login item"),
        ("hotkey.primary", "Primary hotkey", "⌥Space locked"),
        ("theme.appearance", "Appearance", "system / dark / light"),
    ]

    public static func search(query: String) -> [SearchResult] {
        let q = query.lowercased()
        let scoped = q.hasPrefix("settings") || q.hasPrefix("prefs") || q.hasPrefix("preference")
            || q == "settings" || q.hasPrefix("set ")
        guard scoped else { return [] }
        let needle: String
        if q.hasPrefix("settings ") {
            needle = String(q.dropFirst(9))
        } else if q.hasPrefix("prefs ") {
            needle = String(q.dropFirst(6))
        } else if q == "settings" || q == "prefs" {
            needle = ""
        } else {
            needle = q
        }
        return keys
            .filter {
                needle.isEmpty
                    || $0.key.lowercased().contains(needle)
                    || $0.title.lowercased().contains(needle)
            }
            .map {
                SearchResult(
                    id: "settings:\($0.key)",
                    title: $0.title,
                    subtitle: $0.subtitle,
                    kind: .setting,
                    score: 0.8,
                    payload: ["settingsKey": .string($0.key)]
                )
            }
    }
}

/// Onboarding + empty-state catalog (RC-17).
public enum OnboardingCatalog {
    public static func search(query: String) -> [SearchResult] {
        let q = query.lowercased()
        guard q == "welcome" || q == "onboarding" || q == "getting started" || q == "start" else {
            return []
        }
        return [
            SearchResult(
                id: "onboard:1",
                title: "Welcome to Summon",
                subtitle: "⌥Space opens the bar — type to search",
                kind: .command,
                score: 1.0
            ),
            SearchResult(
                id: "onboard:2",
                title: "No account required",
                subtitle: "Local stores · AGPL · agent face",
                kind: .command,
                score: 0.95
            ),
            SearchResult(
                id: "onboard:3",
                title: "Grant Accessibility when asked",
                subtitle: "Window layout + menu search",
                kind: .command,
                score: 0.9
            ),
            SearchResult(
                id: "onboard:4",
                title: "Type ? for help",
                subtitle: "Keyboard shortcuts and roots",
                kind: .command,
                score: 0.9
            ),
        ]
    }
}
