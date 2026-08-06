import Foundation

/// In-bar `?` help guide (RC-58).
///
/// Task-based coverage of the 2026-08-05 native checklist: clipboard controls,
/// ignored applications, window layouts, CJK input, resident operation, relaunch,
/// and the consequences of Quit. Snippet and quicklink *creation* remain the
/// developer CLI until the native-creation product decision (forward pass 13 · W1).
public enum GuideContent {
    public static let lines: [(title: String, body: String)] = [
        ("↑↓", "Navigate results"),
        ("↩", "Run primary action"),
        ("Tab / ⌘K", "Object → action menu"),
        ("Esc", "Close bar / exit actions"),
        ("clip …", "Search clipboard in launcher"),
        (ShortcutCatalog.clipboardHistory, "Open clipboard history (dedicated)"),
        ("Clipboard actions", "In \(ShortcutCatalog.clipboardHistory): Tab a row → Pin, Unpin, or Delete"),
        (
            "Clear clipboard history",
            "\(ShortcutCatalog.clearClipboardHistory), or menu-bar → Clear Clipboard History… — unpinned only, confirms first"
        ),
        ("Ignore an app", "Menu-bar → Manage Ignored Applications… — or Preferences → Clipboard & Privacy"),
        ("snip …", "Search snippets"),
        ("Create snippet", "Type “snippet <name>” → Create snippet… — or CLI: summon-cli snippet add"),
        ("Create quicklink", "Type “quicklink <name>” → Create quicklink… — or CLI: summon-cli quicklink add"),
        ("Add favorite", "Select an app, file, folder, or quicklink → Tab → Add to Favorites"),
        ("app …", "Search apps"),
        ("file …", "Search files"),
        ("kind:pdf", "Filter grammar"),
        ("Type CJK", "Your input source composes marked text inline in the search field"),
        ("Window layouts", "⌃⌥ + arrows/keys — 13 layouts (⌃⌥← half, ⌃⌥↩ maximize) via menu-bar → Window Shortcuts; needs Accessibility"),
        (
            "Runs in the menu bar",
            "Summon stays in the menu-bar icon — \(ShortcutCatalog.launcher) reopens the bar; Esc closes the bar, not the app"
        ),
        ("Launch at login", "Menu-bar → Launch at Login, or Preferences → General"),
        ("Relaunch", "Reopen Summon.app — \(ShortcutCatalog.launcher) returns"),
        (
            "Quit Summon",
            "Menu-bar → Quit Summon (⌘Q) — stops \(ShortcutCatalog.launcher), \(ShortcutCatalog.clipboardHistory), and clipboard capture"
        ),
        ("Preferences", "⌘, — General, Search & Indexing, Clipboard & Privacy, Automation & Agents, Appearance"),
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
