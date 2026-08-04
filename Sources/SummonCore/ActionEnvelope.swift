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
        /// Propose-don't-dispose: destructive/restricted agent·ext ops staged for human accept.
        case staged(proposalID: String)
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

    public var isStaged: Bool {
        if case .staged = outcome { return true }
        return false
    }

    public var stagedProposalID: String? {
        if case .staged(let id) = outcome { return id }
        return nil
    }
}
