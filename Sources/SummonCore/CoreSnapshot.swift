import Foundation

/// Deterministic export of store state for replay equality and JSON export (invariant 2).
public struct CoreSnapshot: Sendable, Hashable, Codable, Equatable {
    public let schemaVersion: Int
    public let settings: [String: JSONValue]
    /// Sorted by id for byte-equal stability.
    public let snippets: [Snippet]

    public init(
        schemaVersion: Int = StoreSchema.version,
        settings: [String: JSONValue],
        snippets: [Snippet] = []
    ) {
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.snippets = snippets.sorted { $0.id < $1.id }
    }

    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    public func canonicalJSONString() throws -> String {
        let data = try canonicalJSON()
        guard let s = String(data: data, encoding: .utf8) else {
            throw CoreError.io("snapshot UTF-8 encode failed")
        }
        return s
    }
}
