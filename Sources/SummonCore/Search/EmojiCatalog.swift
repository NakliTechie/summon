import Foundation

/// Built-in emoji index (offline). Seed from gemoji + colloquial ambiguities.
/// See `EmojiCatalogSeed.swift` and `scripts/generate-emoji-seed.py`.
///
/// Prepared once: lowercased fields + inverted prefix index so free-text does not
/// scan 1.5k × N keyword strings on every keystroke.
public struct EmojiCatalog: Sendable {
    public struct Entry: Sendable, Hashable {
        public let glyph: String
        public let name: String
        public let keywords: [String]

        public init(glyph: String, name: String, keywords: [String]) {
            self.glyph = glyph
            self.name = name
            self.keywords = keywords
        }
    }

    /// Pre-lowercased row for hot search path.
    fileprivate struct Prepared: Sendable {
        let entry: Entry
        let nameLower: String
        let keywordsLower: [String]
        /// name + keywords joined for multi-token checks.
        let blob: String
    }

    public let entries: [Entry]
    private let prepared: [Prepared]
    /// First 1–2 chars of each keyword/name → candidate indices (narrows full scan).
    private let prefixIndex: [String: [Int]]

    public init(entries: [Entry]? = nil) {
        if let entries {
            self.entries = entries
            let built = Self.buildIndex(entries: entries)
            self.prepared = built.prepared
            self.prefixIndex = built.prefixIndex
        } else {
            // Shared prepared index for the default seed (built once).
            let shared = Self.sharedDefault
            self.entries = shared.entries
            self.prepared = shared.prepared
            self.prefixIndex = shared.prefixIndex
        }
    }

    private static let sharedDefault: (entries: [Entry], prepared: [Prepared], prefixIndex: [String: [Int]]) = {
        let entries = seed
        let built = buildIndex(entries: entries)
        return (entries, built.prepared, built.prefixIndex)
    }()

    private static func buildIndex(entries: [Entry]) -> (prepared: [Prepared], prefixIndex: [String: [Int]]) {
        var prepared: [Prepared] = []
        prepared.reserveCapacity(entries.count)
        var index: [String: [Int]] = [:]
        for (i, e) in entries.enumerated() {
            let nameLower = e.name.lowercased()
            let keys = e.keywords.map { $0.lowercased() }
            let blob = ([nameLower] + keys).joined(separator: "\n")
            prepared.append(Prepared(entry: e, nameLower: nameLower, keywordsLower: keys, blob: blob))
            var prefixes = Set<String>()
            func addPrefixes(from s: String) {
                guard !s.isEmpty else { return }
                let a = String(s.prefix(1))
                prefixes.insert(a)
                if s.count >= 2 {
                    prefixes.insert(String(s.prefix(2)))
                }
                // Word tokens for multi-word keywords
                for part in s.split(whereSeparator: { $0.isWhitespace || $0 == "-" }) {
                    let t = String(part)
                    guard !t.isEmpty else { continue }
                    prefixes.insert(String(t.prefix(1)))
                    if t.count >= 2 { prefixes.insert(String(t.prefix(2))) }
                }
            }
            addPrefixes(from: nameLower)
            for k in keys { addPrefixes(from: k) }
            for p in prefixes {
                index[p, default: []].append(i)
            }
        }
        return (prepared, index)
    }

    public func search(query: FilterQuery, limit: Int = 30) -> [SearchResult] {
        if let kind = query.kind, kind != "emoji" { return [] }
        let free = query.freeText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scopedToEmoji = query.kind == "emoji"
        // Free-text single letter matches hundreds of keyword substrings — skip unless scoped.
        if free.count < 2, !scopedToEmoji {
            return []
        }

        let hits: [(Entry, Double)]
        if free.isEmpty {
            hits = prepared.prefix(limit).map { ($0.entry, 0) }
        } else {
            let candidates = candidateIndices(for: free)
            var scored: [(Entry, Double)] = []
            scored.reserveCapacity(min(limit * 2, candidates.count))
            for i in candidates {
                let p = prepared[i]
                if let rank = matchRank(p, free: free) {
                    scored.append((p.entry, rank))
                }
            }
            scored.sort { $0.1 > $1.1 }
            hits = Array(scored.prefix(limit))
        }

        let base = scopedToEmoji ? 750.0 : 450.0
        return hits.enumerated().map { index, pair in
            let (e, rank) = pair
            let score = base + rank * 40.0 - Double(index)
            return SearchResult(
                id: "emoji:\(e.glyph)",
                title: e.glyph,
                subtitle: e.name,
                kind: .emoji,
                score: score,
                payload: [
                    "text": .string(e.glyph),
                    "emoji": .string(e.glyph),
                    "name": .string(e.name),
                ]
            )
        }
    }

    private func candidateIndices(for free: String) -> [Int] {
        let key2 = free.count >= 2 ? String(free.prefix(2)) : String(free.prefix(1))
        if let list = prefixIndex[key2], !list.isEmpty {
            return list
        }
        let key1 = String(free.prefix(1))
        if let list = prefixIndex[key1], !list.isEmpty {
            return list
        }
        // Fallback: full scan (rare for empty prefix)
        return Array(prepared.indices)
    }

    /// Higher is better. `nil` = no match.
    private func matchRank(_ p: Prepared, free: String) -> Double? {
        let entry = p.entry
        if entry.glyph == free
            || entry.glyph.replacingOccurrences(of: "\u{FE0F}", with: "") == free {
            return 1.0
        }
        let name = p.nameLower
        let keys = p.keywordsLower
        if name == free { return 0.98 }
        if keys.contains(free) { return 0.95 }
        if name.hasPrefix(free) { return 0.85 }
        if keys.contains(where: { $0.hasPrefix(free) }) { return 0.8 }
        if name.contains(free) { return 0.7 }
        if keys.contains(where: { $0.contains(free) }) { return 0.65 }
        let tokens = free.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
            .filter { $0.count >= 2 }
        if tokens.count >= 2 {
            if tokens.allSatisfy({ p.blob.contains($0) }) {
                return 0.75
            }
        }
        return nil
    }
}
