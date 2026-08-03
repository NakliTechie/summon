import Foundation

/// Composes S1 sources: calculator, apps, snippets, clipboard, quicklinks, emoji, system, Spotlight.
public struct SearchService: Sendable {
    public var apps: AppCatalog
    public var spotlight: any SpotlightIndexing
    public var snippets: SnippetStore?
    public var clipboard: ClipboardStore?
    public var quicklinks: QuicklinkStore?
    public var emoji: EmojiCatalog
    public var system: SystemCommands

    public init(
        apps: AppCatalog = AppCatalog(),
        spotlight: any SpotlightIndexing = FakeSpotlightIndex(),
        snippets: SnippetStore? = nil,
        clipboard: ClipboardStore? = nil,
        quicklinks: QuicklinkStore? = nil,
        emoji: EmojiCatalog = EmojiCatalog(),
        system: SystemCommands = SystemCommands()
    ) {
        self.apps = apps
        self.spotlight = spotlight
        self.snippets = snippets
        self.clipboard = clipboard
        self.quicklinks = quicklinks
        self.emoji = emoji
        self.system = system
    }

    public func search(_ raw: String, limit: Int = 50) throws -> [SearchResult] {
        let query = try FilterGrammar.parse(raw)
        var results: [SearchResult] = []

        let free = query.freeText.isEmpty ? raw : query.freeText
        if Calculator.looksLikeExpression(free), let calc = Calculator.result(for: free) {
            results.append(calc)
        }

        let kind = query.kind
        let wantApps = kind == nil || kind == "app"
        let wantFiles = kind == nil || ["file", "pdf", "folder", "image", "document"].contains(kind ?? "")
        let wantSnippets = kind == nil || kind == "snippet"
        let wantClipboard = kind == nil || kind == "clipboard"
        let wantQuicklinks = kind == nil || kind == "quicklink"
        let wantEmoji = kind == nil || kind == "emoji"
        let wantSystem = kind == nil || kind == "command" || kind == "system"

        let pureKind = kind != nil
        if wantApps && (!pureKind || kind == "app") {
            results.append(contentsOf: apps.search(query: query, limit: limit))
        }
        if wantSnippets, let snippets {
            results.append(contentsOf: try snippets.search(query: query, limit: limit))
        }
        if wantClipboard, let clipboard {
            results.append(contentsOf: try clipboard.search(query: query, limit: limit))
        }
        if wantQuicklinks, let quicklinks {
            results.append(contentsOf: try quicklinks.search(query: query, limit: limit))
        }
        if wantEmoji && (!pureKind || kind == "emoji") {
            results.append(contentsOf: emoji.search(query: query, limit: limit))
        }
        if wantSystem && (!pureKind || kind == "command" || kind == "system") {
            results.append(contentsOf: system.search(query: query, limit: limit))
        }
        if wantFiles && (!pureKind || !["app", "snippet", "clipboard", "quicklink", "emoji", "command", "system"].contains(kind ?? "")) {
            results.append(contentsOf: try spotlight.search(query: query, limit: limit))
        }

        var seen = Set<String>()
        let deduped = results.filter { seen.insert($0.id).inserted }
        return Array(deduped.sorted { $0.score > $1.score }.prefix(limit))
    }
}
