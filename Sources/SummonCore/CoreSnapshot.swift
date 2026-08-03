import Foundation

/// Deterministic export of store state for replay equality and JSON export (invariant 2).
public struct CoreSnapshot: Sendable, Hashable, Codable, Equatable {
    public let schemaVersion: Int
    public let settings: [String: JSONValue]

    public init(schemaVersion: Int = StoreSchema.version, settings: [String: JSONValue]) {
        self.schemaVersion = schemaVersion
        self.settings = settings
    }

    /// Canonical UTF-8 JSON bytes with sorted keys — used for byte-equal replay checks.
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
