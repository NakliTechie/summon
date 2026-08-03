import Foundation

/// Small built-in emoji index for M1 (expand later). No network.
public struct EmojiCatalog: Sendable {
    public struct Entry: Sendable, Hashable {
        public let glyph: String
        public let name: String
        public let keywords: [String]
    }

    public let entries: [Entry]

    public init(entries: [Entry]? = nil) {
        self.entries = entries ?? Self.seed
    }

    public func search(query: FilterQuery, limit: Int = 30) -> [SearchResult] {
        if let kind = query.kind, kind != "emoji" { return [] }
        let free = query.freeText.lowercased()
        let hits: [Entry]
        if free.isEmpty {
            hits = Array(entries.prefix(limit))
        } else {
            hits = entries.filter {
                $0.name.lowercased().contains(free)
                    || $0.keywords.contains { $0.lowercased().contains(free) }
                    || $0.glyph == free
            }.prefix(limit).map { $0 }
        }
        return hits.enumerated().map { index, e in
            SearchResult(
                id: "emoji:\(e.glyph)",
                title: "\(e.glyph)  \(e.name)",
                subtitle: e.keywords.joined(separator: ", "),
                kind: .emoji,
                score: Double(750 - index),
                payload: [
                    "text": .string(e.glyph),
                    "emoji": .string(e.glyph),
                ]
            )
        }
    }

    private static let seed: [Entry] = [
        Entry(glyph: "✅", name: "check mark", keywords: ["ok", "done", "yes"]),
        Entry(glyph: "❌", name: "cross mark", keywords: ["no", "x", "cancel"]),
        Entry(glyph: "⚠️", name: "warning", keywords: ["alert", "caution"]),
        Entry(glyph: "🔥", name: "fire", keywords: ["hot", "lit"]),
        Entry(glyph: "💡", name: "light bulb", keywords: ["idea"]),
        Entry(glyph: "🚀", name: "rocket", keywords: ["ship", "launch"]),
        Entry(glyph: "📎", name: "paperclip", keywords: ["attach"]),
        Entry(glyph: "🔍", name: "magnifying glass", keywords: ["search", "find"]),
        Entry(glyph: "📋", name: "clipboard", keywords: ["paste", "copy"]),
        Entry(glyph: "⭐️", name: "star", keywords: ["favorite", "fav"]),
        Entry(glyph: "❤️", name: "red heart", keywords: ["love", "like"]),
        Entry(glyph: "👍", name: "thumbs up", keywords: ["yes", "approve"]),
        Entry(glyph: "🎉", name: "party popper", keywords: ["celebrate", "tada"]),
        Entry(glyph: "🐛", name: "bug", keywords: ["debug", "issue"]),
        Entry(glyph: "⚡️", name: "high voltage", keywords: ["fast", "zap"]),
    ]
}
