import Foundation

/// Name scoring on UTF-8 bytes. Tiers, best first: exact name, prefix,
/// substring (word-start beats mid-word), in-order subsequence, then a typo
/// tier (Damerau edit distance against the best-matching substring).
///
/// Comparison lowercases ASCII only; other bytes compare exactly.
enum FuzzyMatcher {
    static let exact: Int32 = 10_000
    static let prefix: Int32 = 8_000
    static let wordSubstring: Int32 = 6_500
    static let substring: Int32 = 5_500
    static let subsequence: Int32 = 3_000
    static let typo: Int32 = 1_500

    @inline(__always)
    static func lower(_ b: UInt8) -> UInt8 {
        (b >= 65 && b <= 90) ? b | 0x20 : b
    }

    /// 64-bit character bag: a–z, 0–9, then 28 hashed buckets for other bytes.
    @inline(__always)
    static func bit(_ b: UInt8) -> UInt64 {
        let c = lower(b)
        if c >= 97 && c <= 122 { return 1 << UInt64(c - 97) }
        if c >= 48 && c <= 57 { return 1 << UInt64(26 + c - 48) }
        return 1 << UInt64(36 + Int(c) % 28)
    }

    static func bag(_ bytes: [UInt8]) -> UInt64 {
        var mask: UInt64 = 0
        for b in bytes { mask |= bit(b) }
        return mask
    }

    /// Edits forgiven for a token of this length: none under 4 bytes, one up to
    /// 7, two from 8.
    static func typoBudget(forLength n: Int) -> Int {
        n < 4 ? 0 : (n < 8 ? 1 : 2)
    }

    @inline(__always)
    static func isBoundary(_ name: UnsafeBufferPointer<UInt8>, _ i: Int) -> Bool {
        if i == 0 { return true }
        let prev = name[i - 1]
        switch prev {
        case UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: " "), UInt8(ascii: "/"):
            return true
        default:
            // camelCase: lower → upper
            let cur = name[i]
            return (prev >= 97 && prev <= 122) && (cur >= 65 && cur <= 90)
        }
    }

    /// Scores `token` (already lowercased) against one name. `original` holds
    /// the name's original-case bytes for camelCase boundaries; `lowered` the
    /// lowercased bytes. Returns 0 when the name does not match.
    static func score(
        token: UnsafeBufferPointer<UInt8>,
        lowered: UnsafeBufferPointer<UInt8>,
        original: UnsafeBufferPointer<UInt8>,
        allowTypos: Bool,
        typoMatcher: TypoMatcher?
    ) -> Int32 {
        let m = token.count
        let n = lowered.count
        guard m > 0 else { return 0 }
        let lengthPenalty = Int32(min(n - m, 200)) * 4
        if m <= n {
            // Substring search (first occurrence, plus whether any sits at a word start).
            var firstHit = -1
            var boundaryHit = false
            let first = token[0]
            var i = 0
            let last = n - m
            while i <= last {
                if lowered[i] == first {
                    var j = 1
                    while j < m && lowered[i + j] == token[j] { j += 1 }
                    if j == m {
                        if i == 0 { return (m == n ? exact : prefix) - lengthPenalty }
                        if firstHit < 0 { firstHit = i }
                        if isBoundary(original, i) {
                            boundaryHit = true
                            break
                        }
                    }
                }
                i += 1
            }
            if firstHit > 0 {
                return (boundaryHit ? wordSubstring : substring) - lengthPenalty - Int32(min(firstHit, 50))
            }
            // In-order subsequence with boundary and adjacency bonuses. A match is
            // kept only when it is compact (spans at most 3 bytes more than the
            // token) or every matched byte starts a word or follows the previous
            // match; otherwise long names match almost any query by scattered letters.
            var ti = 0
            var bonus: Int32 = 0
            var gaps: Int32 = 0
            var prevMatch = -2
            var firstMatch = -1
            var structured = true
            var k = 0
            while k < n && ti < m {
                if lowered[k] == token[ti] {
                    let boundary = isBoundary(original, k)
                    let adjacent = prevMatch == k - 1
                    if boundary { bonus += 60 }
                    if adjacent { bonus += 40 } else if prevMatch >= 0 { gaps += Int32(k - prevMatch - 1) }
                    if !boundary && !adjacent { structured = false }
                    if firstMatch < 0 { firstMatch = k }
                    prevMatch = k
                    ti += 1
                }
                k += 1
            }
            if ti == m, structured || prevMatch - firstMatch + 1 <= m + 3 {
                return subsequence + min(bonus, 1_400) - min(gaps * 8, 1_000) - lengthPenalty
            }
        }
        guard allowTypos, let typoMatcher else { return 0 }
        let edits = typoMatcher.bestDistance(in: lowered)
        guard edits <= typoMatcher.budget else { return 0 }
        return typo - Int32(edits) * 400 - lengthPenalty / 2
    }
}

/// Approximate substring matching under Damerau (optimal string alignment)
/// distance, bit-parallel after Myers (1999) with Hyyrö's transposition term.
/// One pass over the name, about fifteen integer operations per byte.
struct TypoMatcher {
    let budget: Int
    private let length: Int
    private let peq: [UInt64]

    init?(token: [UInt8]) {
        let m = token.count
        let budget = FuzzyMatcher.typoBudget(forLength: m)
        guard budget > 0, m <= 64 else { return nil }
        var peq = [UInt64](repeating: 0, count: 256)
        for (i, b) in token.enumerated() {
            peq[Int(b)] |= 1 << UInt64(i)
        }
        self.budget = budget
        self.length = m
        self.peq = peq
    }

    /// Minimum edits to turn the token into some substring of `text`.
    func bestDistance(in text: UnsafeBufferPointer<UInt8>) -> Int {
        let m = length
        let mask: UInt64 = m == 64 ? ~0 : (1 << UInt64(m)) - 1
        let high: UInt64 = 1 << UInt64(m - 1)
        var vp: UInt64 = mask
        var vn: UInt64 = 0
        var d0: UInt64 = 0
        var prevEq: UInt64 = 0
        var score = m
        var best = m
        peq.withUnsafeBufferPointer { peq in
            for c in text {
                let eq = peq[Int(c)]
                let tr = (((~d0) & eq) << 1) & prevEq
                d0 = ((((eq & vp) &+ vp) ^ vp) | eq | vn | tr) & mask
                var hp = (vn | ~(d0 | vp)) & mask
                var hn = d0 & vp
                if hp & high != 0 { score += 1 } else if hn & high != 0 { score -= 1 }
                hp = (hp << 1) & mask
                hn = (hn << 1) & mask
                vp = (hn | ~(d0 | hp)) & mask
                vn = hp & d0
                prevEq = eq
                if score < best { best = score }
            }
        }
        return best
    }
}
