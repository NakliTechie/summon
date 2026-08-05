import Foundation

public enum PreferencesSection: String, Sendable, CaseIterable {
    case general = "General"
    case search = "Search & Indexing"
    case clipboard = "Clipboard & Privacy"
    case automation = "Automation & Agents"
    case appearance = "Appearance"

    public var destination: AppDestination {
        switch self {
        case .general: return .preferencesGeneral
        case .search: return .preferencesSearch
        case .clipboard: return .preferencesClipboard
        case .automation: return .preferencesAutomation
        case .appearance: return .preferencesAppearance
        }
    }
}

public struct PreferenceDescriptor: Sendable, Equatable {
    public let key: String
    public let title: String
    public let subtitle: String
    public let section: PreferencesSection
}

/// Task-grouped launcher index for the native Preferences window.
public enum SettingsCatalog {
    public static let keys: [PreferenceDescriptor] = [
        PreferenceDescriptor(
            key: "launchAtLogin",
            title: "Launch at login",
            subtitle: "Keep clipboard history ready after sign-in",
            section: .general
        ),
        PreferenceDescriptor(
            key: "hotkey.primary",
            title: "Primary hotkey",
            subtitle: "⌥Space launcher",
            section: .general
        ),
        PreferenceDescriptor(
            key: "hotkey.clipboard",
            title: "Clipboard history hotkey",
            subtitle: "\(ShortcutCatalog.clipboardHistory) dedicated history",
            section: .general
        ),
        PreferenceDescriptor(
            key: "search.fts.enabled",
            title: "Content search",
            subtitle: "Local FTS5 index — explicit consent required",
            section: .search
        ),
        PreferenceDescriptor(
            key: "web.search.enabled",
            title: "Local web search",
            subtitle: "User-owned SearXNG only — default OFF",
            section: .search
        ),
        PreferenceDescriptor(
            key: "web.search.baseURL",
            title: "SearXNG base URL",
            subtitle: "Defaults to http://127.0.0.1:8080",
            section: .search
        ),
        PreferenceDescriptor(
            key: "clipboard.privacy",
            title: "Clipboard privacy",
            subtitle: "History, retention, and ignored applications",
            section: .clipboard
        ),
        PreferenceDescriptor(
            key: "agent.socket.enabled",
            title: "Agent socket",
            subtitle: "Default OFF — local automation boundary",
            section: .automation
        ),
        PreferenceDescriptor(
            key: "theme.appearance",
            title: "Appearance",
            subtitle: "System, dark, or light",
            section: .appearance
        ),
    ]

    public static func destination(for key: String) -> AppDestination {
        keys.first { $0.key == key }?.section.destination ?? .preferencesGeneral
    }

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
                    payload: [
                        "settingsKey": .string($0.key),
                        "destination": .string($0.section.destination.rawValue),
                    ]
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
                subtitle: "Window arrangement shortcuts",
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
