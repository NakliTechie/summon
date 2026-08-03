import Foundation

/// Composes S1 (+ optional S2 FTS): calculator, apps, snippets, clipboard, quicklinks, emoji, system, Spotlight, FTS.
public struct SearchService: Sendable {
    public var apps: AppCatalog
    public var spotlight: any SpotlightIndexing
    public var snippets: SnippetStore?
    public var clipboard: ClipboardStore?
    public var quicklinks: QuicklinkStore?
    public var emoji: EmojiCatalog
    public var system: SystemCommands
    public var frecency: FrecencyStore?
    public var fts: FTSIndex?
    public var ftsEnabled: Bool
    public var favorites: FavoriteStore?
    public var appIntents: AppIntentsSurface

    public init(
        apps: AppCatalog = AppCatalog(),
        spotlight: any SpotlightIndexing = FakeSpotlightIndex(),
        snippets: SnippetStore? = nil,
        clipboard: ClipboardStore? = nil,
        quicklinks: QuicklinkStore? = nil,
        emoji: EmojiCatalog = EmojiCatalog(),
        system: SystemCommands = SystemCommands(),
        frecency: FrecencyStore? = nil,
        fts: FTSIndex? = nil,
        ftsEnabled: Bool = false,
        favorites: FavoriteStore? = nil,
        appIntents: AppIntentsSurface = AppIntentsSurface()
    ) {
        self.apps = apps
        self.spotlight = spotlight
        self.snippets = snippets
        self.clipboard = clipboard
        self.quicklinks = quicklinks
        self.emoji = emoji
        self.system = system
        self.frecency = frecency
        self.fts = fts
        self.ftsEnabled = ftsEnabled
        self.favorites = favorites
        self.appIntents = appIntents
    }

    public func search(_ raw: String, limit: Int = 50) throws -> [SearchResult] {
        let expanded = RootAlias.expandQuery(raw)
        let query = try FilterGrammar.parse(expanded)
        let free = query.freeText.isEmpty ? expanded : query.freeText
        var results: [SearchResult] = []
        results.append(contentsOf: inlineTools(free: free, limit: limit))
        results.append(contentsOf: try storeSources(query: query, free: free, limit: limit))
        results.append(contentsOf: try emptyQueryBoosts(expanded: expanded, limit: limit))
        return try finalize(results, limit: limit)
    }

    private func inlineTools(free: String, limit: Int) -> [SearchResult] {
        var results: [SearchResult] = []
        if Calculator.looksLikeExpression(free), let calc = Calculator.result(for: free) {
            results.append(calc)
        }
        if let unit = UnitConversion.convert(free) { results.append(unit) }
        if let color = ColorPickerUtil.parse(free) { results.append(color) }
        results.append(contentsOf: DevUtils.search(query: free))
        results.append(contentsOf: ProcessControl.search(query: free, limit: min(10, limit)))
        results.append(contentsOf: AltTabModule.search(query: free))
        results.append(contentsOf: ScreenshotModule.search(query: free))
        results.append(contentsOf: BrowserModule.search(query: free))
        results.append(contentsOf: TerminalModule.search(query: free))
        results.append(contentsOf: SystemWidgets.search(query: free))
        results.append(contentsOf: ContactsDictionary.search(query: free))
        results.append(contentsOf: MiscPowerModules.search(query: free))
        if let calHits = try? CalendarSurface().search(query: free) {
            results.append(contentsOf: calHits)
        }
        results.append(contentsOf: SettingsCatalog.search(query: free))
        results.append(contentsOf: OnboardingCatalog.search(query: free))
        let lower = free.lowercased()
        if lower.hasPrefix("action ") || lower.hasPrefix("intent ") || lower.hasPrefix("do ") {
            let needle = free.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            if let hits = try? appIntents.search(query: needle, limit: min(15, limit)) {
                results.append(contentsOf: hits)
            }
        }
        return results
    }

    private func storeSources(query: FilterQuery, free: String, limit: Int) throws -> [SearchResult] {
        var results: [SearchResult] = []
        let kind = query.kind
        let wantApps = kind == nil || kind == "app"
        let wantFiles = kind == nil || ["file", "pdf", "folder", "image", "document"].contains(kind ?? "")
        let wantSnippets = kind == nil || kind == "snippet"
        let wantClipboard = kind == nil || kind == "clipboard"
        let wantQuicklinks = kind == nil || kind == "quicklink"
        let wantEmoji = kind == nil || kind == "emoji"
        let wantSystem = kind == nil || kind == "command" || kind == "system"
        let wantContent = kind == nil || kind == "content" || kind == "fts"
        let pureKind = kind != nil
        let nonFileKinds = ["app", "snippet", "clipboard", "quicklink", "emoji", "command", "system", "content", "fts"]

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
        if wantFiles && (!pureKind || !nonFileKinds.contains(kind ?? "")) {
            results.append(contentsOf: try spotlight.search(query: query, limit: limit))
        }
        if ftsEnabled, wantContent, let fts, !free.isEmpty {
            for doc in try fts.search(query: free, limit: min(limit, 20)) {
                results.append(SearchResult(
                    id: "fts:\(doc.id)",
                    title: doc.title,
                    subtitle: doc.path ?? "content",
                    kind: .file,
                    path: doc.path,
                    score: 0.55,
                    payload: ["fts": .bool(true), "body": .string(String(doc.body.prefix(200)))]
                ))
            }
        }
        return results
    }

    private func emptyQueryBoosts(expanded: String, limit: Int) throws -> [SearchResult] {
        guard expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var results: [SearchResult] = []
        if let favorites {
            for fav in try favorites.all().prefix(limit) {
                let kind = SearchResult.Kind(rawValue: fav.kind) ?? .command
                results.append(SearchResult(
                    id: fav.resultID,
                    title: fav.title,
                    subtitle: "favorite",
                    kind: kind,
                    path: fav.path,
                    score: 0.95
                ))
            }
        }
        if let frecency {
            for entry in try frecency.recents(limit: min(10, limit)) {
                let kind = SearchResult.Kind(rawValue: entry.kind) ?? .command
                results.append(SearchResult(
                    id: entry.resultID,
                    title: entry.title,
                    subtitle: "recent · \(entry.count)×",
                    kind: kind,
                    score: 0.4 + min(0.4, entry.score() / 20)
                ))
            }
        }
        return results
    }

    private func finalize(_ results: [SearchResult], limit: Int) throws -> [SearchResult] {
        var seen = Set<String>()
        var deduped = results.filter { seen.insert($0.id).inserted }
        if let frecency {
            deduped = try deduped.map { r in
                let boost = try frecency.boost(for: r.id)
                guard boost > 0 else { return r }
                return SearchResult(
                    id: r.id,
                    title: r.title,
                    subtitle: r.subtitle,
                    kind: r.kind,
                    path: r.path,
                    score: r.score + min(0.5, boost / 10),
                    payload: r.payload
                )
            }
        }
        return Array(deduped.sorted { $0.score > $1.score }.prefix(limit))
    }
}
