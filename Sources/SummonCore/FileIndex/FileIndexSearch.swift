import Foundation

/// Runs a `FilterQuery` against a `FileNameIndex`.
///
/// Pass 1 scores every distinct name once per query token (parallel chunks).
/// Pass 2 walks entries: at least one token must match the entry's own name;
/// the other tokens may match a folder above it (`fsearch main` finds
/// `…/fsearch/src/main.rs`). Filters (`kind:`, `in:`, `modified:`, `name:`)
/// apply in pass 2. Ranking adds recency and penalises hidden paths and depth;
/// frecency is added later by `SearchService` on the `file:` result id.
enum FileIndexSearch {
    struct Token {
        let bytes: [UInt8]
        /// `name:` tokens must match the entry's own name.
        let nameOnly: Bool
    }

    static let ancestorThreshold = FuzzyMatcher.substring - 200
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "raw"]
    static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "pages", "txt", "md", "rtf", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "csv", "odt",
    ]

    static func tokens(for query: FilterQuery) -> [Token] {
        var result = query.freeText
            .split(whereSeparator: { $0.isWhitespace })
            .map { Token(bytes: Array($0.utf8).map(FuzzyMatcher.lower), nameOnly: false) }
        if let name = query.nameContains?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            result.append(Token(bytes: Array(name.utf8).map(FuzzyMatcher.lower), nameOnly: true))
        }
        return result
    }

    static func search(
        _ index: FileNameIndex,
        query: FilterQuery,
        limit: Int,
        now: Date = Date()
    ) -> [SearchResult] {
        guard limit > 0 else { return [] }
        let tokens = tokens(for: query)
        let hasFilters = query.kind != nil || query.pathPrefix != nil || query.modified != nil
        guard !tokens.isEmpty || hasFilters else { return [] }

        var scopeEntry: Int32?
        if let path = query.pathPrefix {
            guard let entry = index.entry(forPath: path) else { return [] }
            scopeEntry = entry
        }
        let tokenScores = tokens.map { scoreNames(index, token: $0.bytes) }
        let cutoff = query.modified.map { bound -> (Date) -> Bool in { bound.matches(date: $0, now: now) } }
        let nowSeconds = UInt32(clamping: Int(now.timeIntervalSince1970))

        let n = index.entryCount
        let chunk = 1 << 16
        let chunks = (n + chunk - 1) / chunk
        let collector = TopCollector(limit: limit)
        DispatchQueue.concurrentPerform(iterations: max(chunks, 1)) { c in
            var local = BoundedTop(limit: limit)
            let start = c * chunk
            let end = min(n, start + chunk)
            guard start < end else { return }
            for e in start..<end {
                let entry = Int32(e)
                let flags = index.flags[e]
                if flags & FileNameIndex.deletedFlag != 0 || index.parent[e] < 0 { continue }
                guard let total = scoreEntry(
                    index, entry: entry, flags: flags, tokens: tokens, tokenScores: tokenScores,
                    kind: query.kind, scopeEntry: scopeEntry, cutoff: cutoff, nowSeconds: nowSeconds
                ) else { continue }
                local.insert(score: total, entry: entry)
            }
            collector.merge(local)
        }
        return collector.sorted().map { result(index, entry: $0.entry, score: $0.score) }
    }

    /// Per-token score for every distinct name (0 = no match).
    static func scoreNames(_ index: FileNameIndex, token: [UInt8]) -> [Int32] {
        let count = index.nameCount
        var scores = [Int32](repeating: 0, count: count)
        guard count > 0 else { return scores }
        let tokenBag = FuzzyMatcher.bag(token)
        let typo = TypoMatcher(token: token)
        let budget = typo?.budget ?? 0
        let chunk = 1 << 15
        let chunks = (count + chunk - 1) / chunk
        scores.withUnsafeMutableBufferPointer { out in
            index.lowerBytes.withUnsafeBufferPointer { lower in
                index.nameBytes.withUnsafeBufferPointer { original in
                    index.nameOffset.withUnsafeBufferPointer { offsets in
                        index.nameBag.withUnsafeBufferPointer { bags in
                            token.withUnsafeBufferPointer { tok in
                                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                                    let start = c * chunk
                                    let end = min(count, start + chunk)
                                    for id in start..<end {
                                        let missing = (tokenBag & ~bags[id]).nonzeroBitCount
                                        if missing > budget { continue }
                                        let lo = Int(offsets[id])
                                        let hi = Int(offsets[id + 1])
                                        let lowered = UnsafeBufferPointer(rebasing: lower[lo..<hi])
                                        let orig = UnsafeBufferPointer(rebasing: original[lo..<hi])
                                        out[id] = FuzzyMatcher.score(
                                            token: tok,
                                            lowered: lowered,
                                            original: orig,
                                            allowTypos: budget > 0,
                                            typoMatcher: typo
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return scores
    }

    // swiftlint:disable:next function_parameter_count
    private static func scoreEntry(
        _ index: FileNameIndex,
        entry: Int32,
        flags: UInt8,
        tokens: [Token],
        tokenScores: [[Int32]],
        kind: String?,
        scopeEntry: Int32?,
        cutoff: ((Date) -> Bool)?,
        nowSeconds: UInt32
    ) -> Int32? {
        let e = Int(entry)
        let nid = Int(index.nameID[e])
        var total: Int32 = 0
        var matchedOnName = false
        var pending = 0
        for (t, token) in tokens.enumerated() {
            let s = tokenScores[t][nid]
            if s > 0 {
                total += s
                matchedOnName = true
            } else if token.nameOnly {
                return nil
            } else {
                pending |= 1 << t
            }
        }
        if !tokens.isEmpty && !matchedOnName { return nil }
        let isDir = flags & FileNameIndex.directoryFlag != 0
        if let kind, !matchesKind(index, nameID: nid, isDirectory: isDir, kind: kind) { return nil }
        if let cutoff {
            let m = index.mtime[e]
            guard m > 0, cutoff(Date(timeIntervalSince1970: TimeInterval(m))) else { return nil }
        }

        // Walk the folders above: unmatched tokens, `in:` scope, hidden folders, depth.
        var inScope = scopeEntry == nil
        var hidden = startsWithDot(index, nameID: nid)
        var depth: Int32 = 0
        var cursor = index.parent[e]
        while cursor >= 0 {
            let c = Int(cursor)
            if cursor == scopeEntry { inScope = true }
            if index.parent[c] >= 0 {
                let anid = Int(index.nameID[c])
                if pending != 0 {
                    for t in 0..<tokens.count where pending & (1 << t) != 0 && tokenScores[t][anid] >= ancestorThreshold {
                        total += tokenScores[t][anid] / 8
                        pending &= ~(1 << t)
                    }
                }
                if !hidden, startsWithDot(index, nameID: anid) { hidden = true }
                depth += 1
            }
            cursor = index.parent[c]
        }
        guard inScope, pending == 0 else { return nil }

        if tokens.isEmpty {
            // Filter-only query: newest first.
            return Int32(clamping: Int(index.mtime[e]) / 60)
        }
        if hidden { total -= 2_000 }
        total -= min(depth * 15, 300)
        let age = nowSeconds &- index.mtime[e]
        if index.mtime[e] > 0, age < 7 * 86_400 { total += 300 } else if index.mtime[e] > 0, age < 30 * 86_400 { total += 120 }
        return total
    }

    private static func startsWithDot(_ index: FileNameIndex, nameID: Int) -> Bool {
        let lo = Int(index.nameOffset[nameID])
        return lo < Int(index.nameOffset[nameID + 1]) && index.nameBytes[lo] == UInt8(ascii: ".")
    }

    private static func fileExtension(_ index: FileNameIndex, nameID: Int) -> String {
        let range = Int(index.nameOffset[nameID])..<Int(index.nameOffset[nameID + 1])
        guard let dot = index.lowerBytes[range].lastIndex(of: UInt8(ascii: ".")), dot > range.lowerBound else { return "" }
        return String(bytes: index.lowerBytes[(dot + 1)..<range.upperBound], encoding: .utf8) ?? ""
    }

    static func matchesKind(_ index: FileNameIndex, nameID: Int, isDirectory: Bool, kind: String) -> Bool {
        let ext = fileExtension(index, nameID: nameID)
        switch kind {
        case "folder": return isDirectory && ext != "app"
        case "app": return isDirectory && ext == "app"
        case "file": return !isDirectory
        case "pdf": return !isDirectory && ext == "pdf"
        case "image": return !isDirectory && imageExtensions.contains(ext)
        case "document": return !isDirectory && documentExtensions.contains(ext)
        default: return true
        }
    }

    static func result(_ index: FileNameIndex, entry: Int32, score: Int32) -> SearchResult {
        let path = index.path(of: entry)
        let name = index.name(ofEntry: entry)
        let isDir = index.isDirectory(entry)
        let kind: SearchResult.Kind = isDir && name.hasSuffix(".app") ? .app : (isDir ? .folder : .file)
        var payload: [String: JSONValue] = ["index": .bool(true)]
        let m = index.mtime[Int(entry)]
        if m > 0 { payload["mtime"] = .number(Double(m)) }
        return SearchResult(
            id: "file:\(path)",
            title: name,
            subtitle: path,
            kind: kind,
            path: path,
            score: max(0, Double(score) / 10),
            payload: payload
        )
    }
}

/// Fixed-size best-K list (min-heap on score).
struct BoundedTop {
    let limit: Int
    private(set) var items: [(score: Int32, entry: Int32)] = []

    init(limit: Int) { self.limit = limit }

    mutating func insert(score: Int32, entry: Int32) {
        if items.count < limit {
            items.append((score, entry))
            siftUp(items.count - 1)
        } else if let worst = items.first, score > worst.score {
            items[0] = (score, entry)
            siftDown(0)
        }
    }

    private mutating func siftUp(_ i: Int) {
        var child = i
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].score < items[parent].score else { return }
            items.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ i: Int) {
        var parent = i
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            if left < items.count, items[left].score < items[smallest].score { smallest = left }
            if right < items.count, items[right].score < items[smallest].score { smallest = right }
            guard smallest != parent else { return }
            items.swapAt(parent, smallest)
            parent = smallest
        }
    }
}

private final class TopCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var top: BoundedTop

    init(limit: Int) { top = BoundedTop(limit: limit) }

    func merge(_ other: BoundedTop) {
        lock.lock()
        defer { lock.unlock() }
        for item in other.items { top.insert(score: item.score, entry: item.entry) }
    }

    func sorted() -> [(score: Int32, entry: Int32)] {
        lock.lock()
        defer { lock.unlock() }
        // Ties break on entry order (folder order), so results are stable.
        return top.items.sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry < $1.entry }
    }
}
