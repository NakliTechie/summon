import Foundation

/// In-bar `?` help guide (RC-58).
public enum GuideContent {
    public static let lines: [(title: String, body: String)] = [
        ("↑↓", "Navigate results"),
        ("↩", "Run primary action"),
        ("Tab / ⌘K", "Object → action menu"),
        ("Esc", "Close bar / exit actions"),
        ("clip …", "Search clipboard in launcher"),
        (ShortcutCatalog.clipboardHistory, "Open clipboard history (dedicated)"),
        ("snip …", "Search snippets"),
        ("Create snippet", "Developer CLI: summon-cli snippet add <name> <body> [keyword]"),
        ("Create quicklink", "Developer CLI: summon-cli quicklink add <name> <url> [keyword]"),
        ("Add favorite", "Select an app, file, folder, or quicklink → Tab → Add to Favorites"),
        ("app …", "Search apps"),
        ("file …", "Search files"),
        ("kind:pdf", "Filter grammar"),
        ("?", "This help"),
        ("No account", "Local stores only · AGPL"),
        ("AI", "Staged only — never auto-run"),
    ]

    public static func searchResults() -> [SearchResult] {
        lines.enumerated().map { idx, line in
            SearchResult(
                id: "guide:\(idx)",
                title: line.title,
                subtitle: line.body,
                kind: .command,
                score: 1.0 - Double(idx) * 0.01,
                payload: [
                    "guide": .bool(true),
                    "text": .string("\(line.title) — \(line.body)"),
                    "action": .string("snippet.copy"),
                ]
            )
        }
    }
}
