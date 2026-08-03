import Foundation

/// One append-only journal row: fully attributed applied (or rejected) action.
public struct JournalEntry: Sendable, Hashable, Codable, Equatable {
    public let seq: Int64
    public let id: UUID
    public let actor: ActorTag
    public let timestamp: Date
    public let action: CoreAction
    public let outcome: String

    public init(
        seq: Int64,
        id: UUID,
        actor: ActorTag,
        timestamp: Date,
        action: CoreAction,
        outcome: String
    ) {
        self.seq = seq
        self.id = id
        self.actor = actor
        self.timestamp = timestamp
        self.action = action
        self.outcome = outcome
    }

    /// Envelope reconstructed for replay (only applied outcomes should be replayed).
    public var envelope: ActionEnvelope {
        ActionEnvelope(id: id, actor: actor, timestamp: timestamp, action: action)
    }
}
