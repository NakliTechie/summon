import Foundation

/// A fully attributed action ready for the bus.
public struct ActionEnvelope: Sendable, Hashable, Codable, Equatable {
    public let id: UUID
    public let actor: ActorTag
    public let timestamp: Date
    public let action: CoreAction

    public init(
        id: UUID = UUID(),
        actor: ActorTag,
        timestamp: Date = Date(),
        action: CoreAction
    ) {
        self.id = id
        self.actor = actor
        self.timestamp = timestamp
        self.action = action
    }
}

/// Outcome of a bus dispatch.
public struct ActionResult: Sendable, Hashable, Equatable {
    public enum Outcome: Sendable, Hashable, Equatable {
        case applied
        case rejected(reason: String)
        /// Reserved for propose-don't-dispose (AI / agent destructive). Not used in chunk 1.
        case staged
    }

    public let envelopeID: UUID
    public let outcome: Outcome

    public init(envelopeID: UUID, outcome: Outcome) {
        self.envelopeID = envelopeID
        self.outcome = outcome
    }

    public var isApplied: Bool {
        if case .applied = outcome { return true }
        return false
    }
}
