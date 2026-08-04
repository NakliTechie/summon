import Foundation
import GRDB

/// Append-only action journal. Every bus outcome is recorded with `actor=`.
public struct ActionJournal: Sendable {
    private let dbQueue: DatabaseQueue

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func append(envelope: ActionEnvelope, outcome: ActionResult.Outcome) throws {
        let outcomeLabel: String
        switch outcome {
        case .applied: outcomeLabel = "applied"
        case .rejected(let reason): outcomeLabel = "rejected:\(reason)"
        case .staged(let proposalID): outcomeLabel = "staged:\(proposalID)"
        }

        let actionData = try JSONEncoder().encode(envelope.action)
        guard let actionJSON = String(data: actionData, encoding: .utf8) else {
            throw CoreError.journal("action encode failed")
        }
        let ts = Self.isoFormatter.string(from: envelope.timestamp)

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO action_journal (id, actor, timestamp, action_json, outcome)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    envelope.id.uuidString,
                    envelope.actor.journalLabel,
                    ts,
                    actionJSON,
                    outcomeLabel,
                ]
            )
        }
    }

    public func allEntries() throws -> [JournalEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT seq, id, actor, timestamp, action_json, outcome FROM action_journal ORDER BY seq ASC"
            )
            let decoder = JSONDecoder()
            return try rows.map { row in
                let seq: Int64 = row["seq"]
                let idStr: String = row["id"]
                guard let id = UUID(uuidString: idStr) else {
                    throw CoreError.journal("invalid UUID in journal: \(idStr)")
                }
                let actorLabel: String = row["actor"]
                let actor = try ActorTag(journalLabel: actorLabel)
                let tsStr: String = row["timestamp"]
                guard let timestamp = Self.isoFormatter.date(from: tsStr)
                        ?? ISO8601DateFormatter().date(from: tsStr) else {
                    throw CoreError.journal("invalid timestamp: \(tsStr)")
                }
                let actionJSON: String = row["action_json"]
                guard let actionData = actionJSON.data(using: .utf8) else {
                    throw CoreError.journal("action_json not UTF-8 at seq \(seq)")
                }
                let action = try decoder.decode(CoreAction.self, from: actionData)
                let outcome: String = row["outcome"]
                return JournalEntry(
                    seq: seq,
                    id: id,
                    actor: actor,
                    timestamp: timestamp,
                    action: action,
                    outcome: outcome
                )
            }
        }
    }

    /// Entries whose outcome was `applied` — the replay input set.
    public func appliedEntries() throws -> [JournalEntry] {
        try allEntries().filter { $0.outcome == "applied" }
    }
}
