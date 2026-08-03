import Foundation

/// S2 index consent (opt-in before first build — handoff).
public struct FTSConsent: Sendable, Hashable, Codable, Equatable {
    public var granted: Bool
    public var estimatedBytes: Int64
    public var scopedPaths: [String]
    public var grantedAt: Date?

    public static let `default` = FTSConsent(
        granted: false,
        estimatedBytes: 500_000_000,
        scopedPaths: ["~/Documents", "~/Desktop"],
        grantedAt: nil
    )

    public init(granted: Bool, estimatedBytes: Int64, scopedPaths: [String], grantedAt: Date?) {
        self.granted = granted
        self.estimatedBytes = estimatedBytes
        self.scopedPaths = scopedPaths
        self.grantedAt = grantedAt
    }

    public mutating func grant() {
        granted = true
        grantedAt = Date()
    }
}

public struct FTSConsentStore: Sendable {
    public let url: URL

    public init(container: URL) {
        self.url = container.appendingPathComponent("fts-consent.json")
    }

    public func load() -> FTSConsent {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(FTSConsent.self, from: data) else {
            return .default
        }
        return c
    }

    public func save(_ c: FTSConsent) throws {
        let data = try JSONEncoder().encode(c)
        try data.write(to: url, options: .atomic)
    }
}
