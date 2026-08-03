import Foundation

/// Root command aliases (RC-45): `clip foo` scopes to clipboard, etc.
public struct RootAliasResolution: Sendable, Equatable {
    public let scopeKind: String?
    public let remainder: String
    public let aliasUsed: String?

    public init(scopeKind: String?, remainder: String, aliasUsed: String?) {
        self.scopeKind = scopeKind
        self.remainder = remainder
        self.aliasUsed = aliasUsed
    }
}

public enum RootAlias {
    /// Built-in roots. User-learned Quick Keys land in AliasStore later.
    public static let builtins: [String: String] = [
        "clip": "clipboard",
        "clipboard": "clipboard",
        "snip": "snippet",
        "snippet": "snippet",
        "app": "app",
        "apps": "app",
        "file": "file",
        "files": "file",
        "emoji": "emoji",
        "link": "quicklink",
        "links": "quicklink",
        "cmd": "command",
        "sys": "command",
    ]

    public static func resolve(_ raw: String) -> RootAliasResolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(of: " ") else {
            let key = trimmed.lowercased()
            if let kind = builtins[key] {
                return RootAliasResolution(scopeKind: kind, remainder: "", aliasUsed: key)
            }
            return RootAliasResolution(scopeKind: nil, remainder: trimmed, aliasUsed: nil)
        }
        let head = String(trimmed[..<space]).lowercased()
        let rest = String(trimmed[trimmed.index(after: space)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let kind = builtins[head] {
            return RootAliasResolution(scopeKind: kind, remainder: rest, aliasUsed: head)
        }
        return RootAliasResolution(scopeKind: nil, remainder: trimmed, aliasUsed: nil)
    }

    /// Rewrite free text into filter-grammar form when a root is used.
    public static func expandQuery(_ raw: String) -> String {
        let r = resolve(raw)
        guard let kind = r.scopeKind else { return raw }
        if r.remainder.isEmpty {
            return "kind:\(kind)"
        }
        return "kind:\(kind) \(r.remainder)"
    }
}
