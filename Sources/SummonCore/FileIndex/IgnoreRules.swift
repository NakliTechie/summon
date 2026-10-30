import Foundation

/// One line of a `.gitignore` / `.ignore` file, compiled to bytes.
struct IgnoreRule: Sendable, Equatable {
    let pattern: [UInt8]
    let negated: Bool
    let directoryOnly: Bool
    /// A pattern with a `/` before its end matches the path relative to the
    /// file's directory; otherwise it matches the basename at any depth.
    let anchored: Bool

    init?(line raw: Substring) {
        var line = raw
        while let last = line.last, last == " " || last == "\t" || last == "\r" {
            // A trailing space escaped with `\` is kept.
            if line.count >= 2, line[line.index(before: line.index(before: line.endIndex))] == "\\" { break }
            line = line.dropLast()
        }
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        var negated = false
        if line.hasPrefix("!") {
            negated = true
            line = line.dropFirst()
        } else if line.hasPrefix("\\!") || line.hasPrefix("\\#") {
            line = line.dropFirst()
        }
        var directoryOnly = false
        if line.hasSuffix("/") {
            directoryOnly = true
            line = line.dropLast()
        }
        guard !line.isEmpty else { return nil }
        var anchored = line.contains("/")
        if line.hasPrefix("/") {
            line = line.dropFirst()
            anchored = true
        }
        // `**/x` behaves like an unanchored `x` only for the basename case; keep it
        // anchored and let `**/` match zero or more leading directories.
        guard !line.isEmpty else { return nil }
        self.pattern = Array(line.utf8)
        self.negated = negated
        self.directoryOnly = directoryOnly
        self.anchored = anchored
    }

    /// `relativePath` is relative to the directory holding the ignore file.
    func matches(relativePath: [UInt8], basename: [UInt8], isDirectory: Bool) -> Bool {
        if directoryOnly, !isDirectory { return false }
        let subject = anchored ? relativePath : basename
        return GlobMatcher.match(pattern, 0, subject, 0)
    }
}

/// gitignore glob semantics on bytes: `*` and `?` stop at `/`, `**` crosses it,
/// `**/` also matches zero directories, `[...]` classes with `!`/`^` and ranges.
enum GlobMatcher {
    static func match(_ p: [UInt8], _ pi: Int, _ s: [UInt8], _ si: Int) -> Bool {
        var pi = pi
        var si = si
        let slash = UInt8(ascii: "/")
        while pi < p.count {
            let c = p[pi]
            if c == UInt8(ascii: "*") {
                if pi + 1 < p.count, p[pi + 1] == UInt8(ascii: "*") {
                    let next = pi + 2
                    if next < p.count, p[next] == slash {
                        if match(p, next + 1, s, si) { return true }
                        var k = si
                        while k < s.count {
                            if s[k] == slash, match(p, next + 1, s, k + 1) { return true }
                            k += 1
                        }
                        return false
                    }
                    var k = si
                    while k <= s.count {
                        if match(p, next, s, k) { return true }
                        k += 1
                    }
                    return false
                }
                var k = si
                while true {
                    if match(p, pi + 1, s, k) { return true }
                    if k == s.count || s[k] == slash { return false }
                    k += 1
                }
            }
            guard si < s.count else { return false }
            switch c {
            case UInt8(ascii: "?"):
                if s[si] == slash { return false }
                pi += 1
                si += 1
            case UInt8(ascii: "["):
                guard let (matched, end) = matchClass(p, pi, s[si]) else {
                    // Unterminated class: treat `[` literally.
                    if s[si] != c { return false }
                    pi += 1
                    si += 1
                    continue
                }
                if !matched { return false }
                pi = end
                si += 1
            case UInt8(ascii: "\\") where pi + 1 < p.count:
                if s[si] != p[pi + 1] { return false }
                pi += 2
                si += 1
            default:
                if s[si] != c { return false }
                pi += 1
                si += 1
            }
        }
        return si == s.count
    }

    /// Returns whether `ch` is in the class starting at `p[start] == "["`, and the
    /// index just past the closing `]`; nil when the class is unterminated.
    private static func matchClass(_ p: [UInt8], _ start: Int, _ ch: UInt8) -> (Bool, Int)? {
        var i = start + 1
        var negate = false
        if i < p.count, p[i] == UInt8(ascii: "!") || p[i] == UInt8(ascii: "^") {
            negate = true
            i += 1
        }
        var matched = false
        var first = true
        while i < p.count {
            let c = p[i]
            if c == UInt8(ascii: "]"), !first {
                return (matched != negate, i + 1)
            }
            first = false
            if i + 2 < p.count, p[i + 1] == UInt8(ascii: "-"), p[i + 2] != UInt8(ascii: "]") {
                if ch >= c && ch <= p[i + 2] { matched = true }
                i += 3
            } else {
                if ch == c { matched = true }
                i += 1
            }
        }
        return nil
    }
}

/// The ignore files in force for one directory: an immutable chain from the
/// repository root down, so siblings share their parents' rules.
final class IgnoreScope: @unchecked Sendable {
    let directory: [UInt8]
    let rules: [IgnoreRule]
    let parent: IgnoreScope?

    init(directory: String, rules: [IgnoreRule], parent: IgnoreScope?) {
        self.directory = Array(directory.utf8)
        self.rules = rules
        self.parent = parent
    }

    static let ignoreFileNames = [".gitignore", ".ignore"]

    static func parse(_ text: String) -> [IgnoreRule] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap(IgnoreRule.init(line:))
    }

    static func loadRules(in directory: String, includeGitInfoExclude: Bool) -> [IgnoreRule] {
        var rules: [IgnoreRule] = []
        if includeGitInfoExclude,
           let text = try? String(contentsOfFile: directory + "/.git/info/exclude", encoding: .utf8) {
            rules += parse(text)
        }
        for name in ignoreFileNames {
            if let text = try? String(contentsOfFile: directory + "/" + name, encoding: .utf8) {
                rules += parse(text)
            }
        }
        return rules
    }

    /// Last matching rule wins, inner files over outer ones (git semantics).
    func isIgnored(path: [UInt8], basename: [UInt8], isDirectory: Bool) -> Bool {
        var scopes: [IgnoreScope] = []
        var cursor: IgnoreScope? = self
        while let scope = cursor {
            scopes.append(scope)
            cursor = scope.parent
        }
        var ignored = false
        for scope in scopes.reversed() where !scope.rules.isEmpty {
            guard path.count > scope.directory.count + 1 else { continue }
            let relative = Array(path[(scope.directory.count + 1)...])
            for rule in scope.rules where rule.matches(relativePath: relative, basename: basename, isDirectory: isDirectory) {
                ignored = !rule.negated
            }
        }
        return ignored
    }

    /// Rebuilds the scope for an arbitrary directory (used when a watcher event
    /// lands mid-tree): finds the enclosing repository and stacks every ignore
    /// file from its root down to `directory`. Nil outside a repository.
    static func enclosing(directory: String) -> IgnoreScope? {
        var components = directory.split(separator: "/").map(String.init)
        var repoDepth: Int?
        var depth = components.count
        while depth > 0 {
            let candidate = "/" + components.prefix(depth).joined(separator: "/")
            if FileManager.default.fileExists(atPath: candidate + "/.git") {
                repoDepth = depth
                break
            }
            depth -= 1
        }
        guard let root = repoDepth else { return nil }
        var scope: IgnoreScope?
        for level in root...components.count {
            let dir = "/" + components.prefix(level).joined(separator: "/")
            let rules = loadRules(in: dir, includeGitInfoExclude: level == root)
            scope = IgnoreScope(directory: dir, rules: rules, parent: scope)
        }
        components.removeAll()
        return scope
    }
}
