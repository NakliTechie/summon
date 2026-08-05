import Foundation

/// Spotlight/HoudahSpot-style filter grammar for S1 (vision M1).
///
/// Free text plus space-separated `key:value` tokens:
/// `invoice kind:pdf modified:<7d in:~/Documents`
public struct FilterQuery: Sendable, Hashable, Equatable {
    public let freeText: String
    public let filters: [FilterClause]

    public init(freeText: String, filters: [FilterClause]) {
        self.freeText = freeText
        self.filters = filters
    }

    public var kind: String? {
        filters.compactMap { if case .kind(let k) = $0 { return k } else { return nil } }.first
    }

    public var modified: RelativeDateBound? {
        filters.compactMap { if case .modified(let b) = $0 { return b } else { return nil } }.first
    }

    public var pathPrefix: String? {
        filters.compactMap { if case .path(let p) = $0 { return p } else { return nil } }.first
    }

    public var nameContains: String? {
        filters.compactMap { if case .name(let n) = $0 { return n } else { return nil } }.first
    }
}

public enum FilterClause: Sendable, Hashable, Equatable {
    case kind(String)
    case modified(RelativeDateBound)
    case path(String)
    case name(String)
    /// Unknown key preserved so callers can surface an error or ignore.
    case unknown(key: String, value: String)
}

public enum RelativeDateBound: Sendable, Hashable, Equatable {
    /// Strictly older than the duration (e.g. `modified:>30d` = older than 30 days).
    case olderThan(DateComponents)
    /// Within the duration (e.g. `modified:<7d` = last 7 days).
    case within(DateComponents)
    case before(DateComponents)
    case after(DateComponents)

    public func matches(date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .within(let comps), .before(let comps):
            guard let start = calendar.date(byAdding: comps.negated, to: now) else { return false }
            return date >= start && date <= now
        case .olderThan(let comps), .after(let comps):
            // olderThan / after both mean "before the cutoff in the past"
            guard let cutoff = calendar.date(byAdding: comps.negated, to: now) else { return false }
            return date < cutoff
        }
    }
}

public enum FilterGrammar {
    public static func parse(_ raw: String) throws -> FilterQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return FilterQuery(freeText: "", filters: [])
        }

        var freeParts: [String] = []
        var filters: [FilterClause] = []

        // Tokenize on whitespace; tokens with `key:value` (no space around colon) are filters.
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for token in tokens {
            if let colon = token.firstIndex(of: ":"), colon != token.startIndex {
                let key = String(token[..<colon]).lowercased()
                let value = String(token[token.index(after: colon)...])
                if Self.knownKeys.contains(key), !value.isEmpty {
                    filters.append(try parseClause(key: key, value: value))
                } else {
                    freeParts.append(token)
                }
            } else {
                freeParts.append(token)
            }
        }

        return FilterQuery(freeText: freeParts.joined(separator: " "), filters: filters)
    }

    private static let knownKeys: Set<String> = [
        "kind", "type", "k",
        "modified", "mod", "mtime", "date",
        "in", "path", "dir",
        "name", "n",
    ]

    private static func parseClause(key: String, value: String) throws -> FilterClause {
        switch key {
        case "kind", "type", "k":
            return .kind(normalizeKind(value))
        case "modified", "mod", "mtime", "date":
            return .modified(try parseRelativeDate(value))
        case "in", "path", "dir":
            return .path((value as NSString).expandingTildeInPath)
        case "name", "n":
            return .name(value)
        default:
            preconditionFailure("parseClause called for unknown filter key")
        }
    }

    private static func normalizeKind(_ raw: String) -> String {
        let v = raw.lowercased()
        switch v {
        case "application", "applications", "apps": return "app"
        case "folder", "folders", "dir", "directory": return "folder"
        case "image", "images", "img", "png", "jpg", "jpeg", "gif", "heic": return "image"
        case "document", "documents", "doc": return "document"
        case "pdf": return "pdf"
        case "snippet", "snippets": return "snippet"
        default: return v
        }
    }

    /// Parse `<7d`, `>30d`, `7d` (alias of `<7d`), `12h`, `2w`, `1y`.
    public static func parseRelativeDate(_ raw: String) throws -> RelativeDateBound {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var mode: Character = "<"
        if s.hasPrefix("<") || s.hasPrefix(">") {
            mode = s.first!
            s = String(s.dropFirst())
        }
        guard let last = s.last, let amount = Int(s.dropLast()), amount >= 0 else {
            throw CoreError.schemaValidation("invalid relative date '\(raw)' (expected e.g. <7d, >30d, 12h)")
        }
        let unit = last.lowercased()
        var comps = DateComponents()
        switch unit {
        case "m": comps.minute = amount
        case "h": comps.hour = amount
        case "d": comps.day = amount
        case "w": comps.day = amount * 7
        case "y": comps.year = amount
        default:
            throw CoreError.schemaValidation("unknown date unit '\(unit)' in '\(raw)'")
        }
        switch mode {
        case ">": return .olderThan(comps)
        default: return .within(comps)
        }
    }
}

private extension DateComponents {
    var negated: DateComponents {
        var c = DateComponents()
        if let v = year { c.year = -v }
        if let v = month { c.month = -v }
        if let v = day { c.day = -v }
        if let v = hour { c.hour = -v }
        if let v = minute { c.minute = -v }
        if let v = second { c.second = -v }
        return c
    }
}
