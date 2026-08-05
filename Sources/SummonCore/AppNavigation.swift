import Foundation

/// App-owned destinations that a headless result may request from the native host.
public enum AppDestination: String, Sendable, Codable, CaseIterable {
    case search = "search.all"
    case clipboard
    case help
    case preferencesGeneral = "preferences.general"
    case preferencesSearch = "preferences.search"
    case preferencesClipboard = "preferences.clipboard"
    case preferencesAutomation = "preferences.automation"
    case preferencesAppearance = "preferences.appearance"
}

/// Routable rows shown before the user has typed a query.
public enum LauncherStarterCatalog {
    public static let firstRunSeenKey = "onboarding.launcher.seen"

    public static func results(firstRun: Bool) -> [SearchResult] {
        [
            navigationResult(
                id: "starter:apps",
                title: "Start a search",
                subtitle: firstRun
                    ? "Start typing, or choose a focused search"
                    : "Browse installed apps",
                destination: .search,
                score: 2.0
            ),
            SearchResult(
                id: "starter:calculate",
                title: "Calculate 2+2",
                subtitle: "Copy result: 4",
                kind: .calculation,
                score: 1.9,
                payload: ["text": .string("4")]
            ),
            navigationResult(
                id: "starter:clipboard",
                title: "Clipboard history",
                subtitle: "\(ShortcutCatalog.clipboardHistory) · stored locally on this Mac",
                destination: .clipboard,
                score: 1.8
            ),
            navigationResult(
                id: "starter:preferences",
                title: "Preferences",
                subtitle: "General, search, privacy, automation, and appearance",
                destination: .preferencesGeneral,
                score: 1.7
            ),
            navigationResult(
                id: "starter:help",
                title: "Help and shortcuts",
                subtitle: "? Help · ⌥Space launcher",
                destination: .help,
                score: 1.6
            ),
        ]
    }

    public static func combined(firstRun: Bool, stored: [SearchResult]) -> [SearchResult] {
        var seen = Set<String>()
        return (results(firstRun: firstRun) + stored).filter { seen.insert($0.id).inserted }
    }

    private static func navigationResult(
        id: String,
        title: String,
        subtitle: String,
        destination: AppDestination,
        score: Double
    ) -> SearchResult {
        SearchResult(
            id: id,
            title: title,
            subtitle: subtitle,
            kind: .command,
            score: score,
            payload: [
                "action": .string("app.navigate"),
                "destination": .string(destination.rawValue),
            ]
        )
    }
}
