import Foundation
import GRDB

public struct JournalCorruption: Sendable, Hashable, Equatable {
    public let seq: Int64?
    public let reason: String

    public init(seq: Int64?, reason: String) {
        self.seq = seq
        self.reason = reason
    }
}

public struct JournalReadResult: Sendable, Equatable {
    public let entries: [JournalEntry]
    public let corruptions: [JournalCorruption]
    public let didReachMaterializationLimit: Bool

    public init(
        entries: [JournalEntry],
        corruptions: [JournalCorruption],
        didReachMaterializationLimit: Bool = false
    ) {
        self.entries = entries
        self.corruptions = corruptions
        self.didReachMaterializationLimit = didReachMaterializationLimit
    }
}

/// Append-only action journal. Every bus outcome is recorded with `actor=`.
public struct ActionJournal: Sendable {
    public static let maximumMaterializedEntries = 100_000
    public static let maximumMaterializedActionBytes = 16 * 1_024 * 1_024
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
        try dbQueue.write { db in
            try append(envelope: envelope, outcome: outcome, in: db)
        }
    }

    func append(
        envelope: ActionEnvelope,
        outcome: ActionResult.Outcome,
        in db: Database
    ) throws {
        try insert(envelope: envelope, outcomeLabel: Self.label(for: outcome), in: db)
    }

    func reserveEffect(_ envelope: ActionEnvelope, in db: Database) throws -> String? {
        if let existing = try outcomeLabel(envelopeID: envelope.id, in: db) {
            return existing
        }
        try insert(envelope: envelope, outcomeLabel: "intent", in: db)
        return nil
    }

    func updateOutcome(
        envelopeID: UUID,
        outcome: ActionResult.Outcome,
        in db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE action_journal SET outcome = ? WHERE id = ? AND outcome = 'intent'",
            arguments: [Self.label(for: outcome), envelopeID.uuidString]
        )
        guard db.changesCount == 1 else {
            throw CoreError.journal("effect intent missing for \(envelopeID.uuidString)")
        }
    }

    func outcome(envelopeID: UUID, in db: Database) throws -> ActionResult.Outcome? {
        guard let label = try outcomeLabel(envelopeID: envelopeID, in: db) else { return nil }
        return Self.outcome(from: label)
    }

    func outcomeLabel(envelopeID: UUID, in db: Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT outcome FROM action_journal WHERE id = ?",
            arguments: [envelopeID.uuidString]
        )
    }

    private func insert(
        envelope: ActionEnvelope,
        outcomeLabel: String,
        in db: Database
    ) throws {

        let actionData = try JSONEncoder().encode(envelope.action)
        guard let actionJSON = String(data: actionData, encoding: .utf8) else {
            throw CoreError.journal("action encode failed")
        }
        let ts = Self.isoFormatter.string(from: envelope.timestamp)

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

    static func outcome(from label: String) -> ActionResult.Outcome? {
        if label == "applied" { return .applied }
        if label.hasPrefix("rejected:") {
            return .rejected(reason: String(label.dropFirst("rejected:".count)))
        }
        if label.hasPrefix("staged:") {
            return .staged(proposalID: String(label.dropFirst("staged:".count)))
        }
        return nil
    }

    private static func label(for outcome: ActionResult.Outcome) -> String {
        switch outcome {
        case .applied: return "applied"
        case .rejected(let reason): return "rejected:\(reason)"
        case .staged(let proposalID): return "staged:\(proposalID)"
        }
    }

    public func allEntries() throws -> [JournalEntry] {
        let result = try readAll()
        guard !result.didReachMaterializationLimit else {
            throw CoreError.journal("journal exceeds the bounded materialization limit")
        }
        return result.entries
    }

    public func entry(id: UUID) throws -> JournalEntry? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT seq, id, actor, timestamp, action_json, outcome
                    FROM action_journal
                    WHERE id = ?
                    """,
                arguments: [id.uuidString]
            ) else {
                return nil
            }
            return try Self.decode(row: row, decoder: JSONDecoder())
        }
    }

    func exportRecords(
        in db: Database,
        maximumEntries: Int = 1_000
    ) throws -> (records: [JournalExportRecord], totalCount: Int) {
        let limit = max(0, maximumEntries)
        let totalCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM action_journal") ?? 0
        guard limit > 0 else { return ([], totalCount) }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT seq, id, actor, timestamp, action_json, outcome
                FROM action_journal
                ORDER BY seq DESC
                LIMIT ?
                """,
            arguments: [limit]
        )
        let decoder = JSONDecoder()
        let records = rows.reversed().compactMap { row -> JournalExportRecord? in
            guard let entry = try? Self.decode(row: row, decoder: decoder) else { return nil }
            return JournalExportRecord(
                seq: entry.seq,
                id: entry.id,
                actor: entry.actor,
                timestamp: entry.timestamp,
                actionName: entry.action.name,
                outcome: entry.outcome
            )
        }
        return (records, totalCount)
    }

    /// Streams rows so one malformed journal entry does not hide later valid entries.
    public func readAll(
        maximumEntries: Int = Self.maximumMaterializedEntries,
        maximumActionBytes: Int = Self.maximumMaterializedActionBytes
    ) throws -> JournalReadResult {
        try dbQueue.read { db in
            let cursor = try Row.fetchCursor(
                db,
                sql: "SELECT seq, id, actor, timestamp, action_json, outcome FROM action_journal ORDER BY seq ASC"
            )
            let decoder = JSONDecoder()
            var entries: [JournalEntry] = []
            var corruptions: [JournalCorruption] = []
            var processedEntries = 0
            var materializedActionBytes = 0
            var didReachLimit = false
            while let row = try cursor.next() {
                let actionJSON: String = row["action_json"]
                let actionBytes = actionJSON.utf8.count
                if processedEntries >= max(0, maximumEntries)
                    || actionBytes > max(0, maximumActionBytes - materializedActionBytes) {
                    didReachLimit = true
                    break
                }
                processedEntries += 1
                materializedActionBytes += actionBytes
                let seq = row["seq"] as Int64?
                do {
                    entries.append(try Self.decode(row: row, decoder: decoder))
                } catch {
                    corruptions.append(JournalCorruption(
                        seq: seq,
                        reason: Self.corruptionReason(error)
                    ))
                }
            }
            return JournalReadResult(
                entries: entries,
                corruptions: corruptions,
                didReachMaterializationLimit: didReachLimit
            )
        }
    }

    private static func decode(row: Row, decoder: JSONDecoder) throws -> JournalEntry {
        let seq: Int64 = row["seq"]
        let idStr: String = row["id"]
        guard let id = UUID(uuidString: idStr) else {
            throw CoreError.journal("invalid UUID")
        }
        let actorLabel: String = row["actor"]
        let actor = try ActorTag(journalLabel: actorLabel)
        let tsStr: String = row["timestamp"]
        guard let timestamp = Self.isoFormatter.date(from: tsStr)
                ?? ISO8601DateFormatter().date(from: tsStr) else {
            throw CoreError.journal("invalid timestamp")
        }
        let actionJSON: String = row["action_json"]
        guard let actionData = actionJSON.data(using: .utf8) else {
            throw CoreError.journal("action_json is not UTF-8")
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

    private static func corruptionReason(_ error: Error) -> String {
        if let coreError = error as? CoreError {
            switch coreError {
            case .journal(let message):
                return String(message.prefix(256))
            case .invalidActor:
                return "invalid actor"
            case .unknownAction, .schemaValidation:
                return "action_json failed schema decoding"
            case .store, .io:
                return "row failed validation"
            }
        }
        if error is DecodingError { return "action_json failed schema decoding" }
        return "row failed validation"
    }

    /// Entries whose outcome was `applied` — the replay input set.
    public func appliedEntries() throws -> [JournalEntry] {
        try allEntries().filter { $0.outcome == "applied" }
    }
}
