import Foundation

/// Unified launcher result row (apps, files, snippets, calculations, …).
public struct SearchResult: Sendable, Hashable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable, Equatable {
        case app
        case file
        case folder
        case snippet
        case calculation
        case setting
        case command
        case clipboard
        case quicklink
        case emoji
    }

    public let id: String
    public let title: String
    public let subtitle: String?
    public let kind: Kind
    public let path: String?
    public let score: Double
    public let payload: [String: JSONValue]

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        kind: Kind,
        path: String? = nil,
        score: Double = 0,
        payload: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.path = path
        self.score = score
        self.payload = payload
    }
}
