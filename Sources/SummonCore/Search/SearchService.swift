import Foundation

/// Composes S1 sources: calculator, apps, snippets, Spotlight.
public struct SearchService: Sendable {
    public var apps: AppCatalog
    public var spotlight: any SpotlightIndexing
    public var snippets: SnippetStore?

    public init(
        apps: AppCatalog = AppCatalog(),
        spotlight: any SpotlightIndexing = FakeSpotlightIndex(),
        snippets: SnippetStore? = nil
    ) {
        self.apps = apps
        self.spotlight = spotlight
        self.snippets = snippets
    }

    public func search(_ raw: String, limit: Int = 50) throws -> [SearchResult] {
        let query = try FilterGrammar.parse(raw)
        var results: [SearchResult] = []

        if let calc = Calculator.result(for: query.freeText.isEmpty ? raw : query.freeText) {
            // Only inject calc when free text is expression-like (ignore pure filters).
            if Calculator.looksLikeExpression(query.freeText.isEmpty ? raw : query.freeText) {
                results.append(calc)
            }
        }

        let kind = query.kind
        let wantApps = kind == nil || kind == "app"
        let wantFiles = kind == nil || (kind != "app" && kind != "snippet")
        let wantSnippets = kind == nil || kind == "snippet"

        if wantApps {
            results.append(contentsOf: apps.search(query: query, limit: limit))
        }
        if wantSnippets, let snippets {
            results.append(contentsOf: try snippets.search(query: query, limit: limit))
        }
        if wantFiles {
            results.append(contentsOf: try spotlight.search(query: query, limit: limit))
        }

        // De-dupe by id, sort by score descending.
        var seen = Set<String>()
        let deduped = results.filter { seen.insert($0.id).inserted }
        return Array(deduped.sorted { $0.score > $1.score }.prefix(limit))
    }
}
