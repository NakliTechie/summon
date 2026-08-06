import Foundation

/// Launcher-inline creation for snippets and quicklinks (native, no CLI).
///
/// Surfaces "Create snippet…" / "Create quicklink…" commands when the query
/// signals create intent (e.g. `new`, `snippet <name>`, `create quicklink`).
/// The UI intercepts the `create.snippet` / `create.quicklink` payload action
/// and opens an input form that dispatches `.snippetUpsert` / `.quicklinkUpsert`.
public enum CreateActionCatalog {
    private enum Kind: String { case snippet, quicklink }

    public static func search(query: String) -> [SearchResult] {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        let q = raw.lowercased()

        if q == "new" || q == "create" || q == "add" {
            return [make(.snippet, seed: ""), make(.quicklink, seed: "")]
        }
        var out: [SearchResult] = []
        if let seed = seed(raw, q, ["new snippet", "add snippet", "create snippet", "snippet"]) {
            out.append(make(.snippet, seed: seed))
        }
        if let seed = seed(raw, q, ["new quicklink", "add quicklink", "create quicklink", "quicklink"]) {
            out.append(make(.quicklink, seed: seed))
        }
        return out
    }

    /// Returns the trailing name for the first matching prefix, or nil if none match.
    private static func seed(_ raw: String, _ q: String, _ prefixes: [String]) -> String? {
        for prefix in prefixes {
            if q == prefix { return "" }
            if q.hasPrefix(prefix + " ") {
                return String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func make(_ kind: Kind, seed: String) -> SearchResult {
        let word = kind.rawValue
        let subtitle = seed.isEmpty ? "Create a new \(word)" : "Create \(word) “\(seed)”"
        return SearchResult(
            id: "create:\(word)",
            title: "Create \(word)…",
            subtitle: subtitle,
            kind: .command,
            score: 0.72,
            payload: [
                "action": .string("create.\(word)"),
                "seedName": .string(seed),
            ]
        )
    }
}
