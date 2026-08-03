import Foundation

/// App Intents enumeration surface (M2). Pure models + protocol so tests don't need AppIntents runtime.
public struct AppIntentDescriptor: Sendable, Hashable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let bundleID: String
    public let abbreviation: String?

    public init(id: String, title: String, bundleID: String, abbreviation: String? = nil) {
        self.id = id
        self.title = title
        self.bundleID = bundleID
        self.abbreviation = abbreviation
    }
}

public protocol AppIntentEnumerating: Sendable {
    func enumerate() throws -> [AppIntentDescriptor]
}

/// Fixture enumerator for headless tests and until live AppIntents wiring lands.
public struct FakeAppIntentEnumerator: AppIntentEnumerating, Sendable {
    public var intents: [AppIntentDescriptor]

    public init(intents: [AppIntentDescriptor] = [
        AppIntentDescriptor(
            id: "com.apple.MobileSMS.open",
            title: "Open Messages",
            bundleID: "com.apple.MobileSMS",
            abbreviation: "msg"
        ),
        AppIntentDescriptor(
            id: "com.apple.mail.compose",
            title: "Compose Email",
            bundleID: "com.apple.mail",
            abbreviation: "eml"
        ),
    ]) {
        self.intents = intents
    }

    public func enumerate() throws -> [AppIntentDescriptor] {
        intents
    }
}

public struct AppIntentsSurface: Sendable {
    public var enumerator: any AppIntentEnumerating

    public init(enumerator: any AppIntentEnumerating = FakeAppIntentEnumerator()) {
        self.enumerator = enumerator
    }

    public func search(query: String, limit: Int = 30) throws -> [SearchResult] {
        let all = try enumerator.enumerate()
        let q = query.lowercased()
        let hits = all.filter {
            q.isEmpty
                || $0.title.lowercased().contains(q)
                || $0.bundleID.lowercased().contains(q)
                || ($0.abbreviation?.lowercased().contains(q) ?? false)
        }.prefix(limit)
        return hits.enumerated().map { index, intent in
            SearchResult(
                id: "intent:\(intent.id)",
                title: intent.title,
                subtitle: intent.bundleID,
                kind: .command,
                score: Double(760 - index),
                payload: [
                    "intentID": .string(intent.id),
                    "bundleID": .string(intent.bundleID),
                ]
            )
        }
    }
}
