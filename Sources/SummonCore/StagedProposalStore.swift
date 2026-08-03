import Foundation
import GRDB

/// Persist staged AI proposals (accept/reject survives restarts).
public struct PersistedStagedProposal: Sendable, Hashable, Codable, Equatable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let rung: String
    public let prompt: String
    public let output: String
    public let egressSummary: String
    public var state: String // staged | accepted | rejected

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        rung: String,
        prompt: String,
        output: String,
        egressSummary: String = "",
        state: String = "staged"
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rung = rung
        self.prompt = prompt
        self.output = output
        self.egressSummary = egressSummary
        self.state = state
    }
}

public struct StagedProposalStore: Sendable {
    private let dbQueue: DatabaseQueue
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS staged_proposals (
                    id TEXT PRIMARY KEY NOT NULL,
                    created_at TEXT NOT NULL,
                    rung TEXT NOT NULL,
                    prompt TEXT NOT NULL,
                    output TEXT NOT NULL,
                    egress TEXT NOT NULL,
                    state TEXT NOT NULL
                );
                """)
        }
    }

    public func upsert(_ p: PersistedStagedProposal) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO staged_proposals (id, created_at, rung, prompt, output, egress, state)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET state = excluded.state, output = excluded.output
                    """,
                arguments: [
                    p.id,
                    Self.iso.string(from: p.createdAt),
                    p.rung,
                    p.prompt,
                    p.output,
                    p.egressSummary,
                    p.state,
                ]
            )
        }
    }

    public func get(_ id: String) throws -> PersistedStagedProposal? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM staged_proposals WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return try Self.from(row)
        }
    }

    public func list(state: String? = "staged") throws -> [PersistedStagedProposal] {
        try dbQueue.read { db in
            let rows: [Row]
            if let state {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM staged_proposals WHERE state = ? ORDER BY created_at DESC",
                    arguments: [state]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM staged_proposals ORDER BY created_at DESC"
                )
            }
            return try rows.map { try Self.from($0) }
        }
    }

    public func setState(id: String, state: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE staged_proposals SET state = ? WHERE id = ?",
                arguments: [state, id]
            )
        }
    }

    private static func from(_ row: Row) throws -> PersistedStagedProposal {
        let ts: String = row["created_at"]
        let date = iso.date(from: ts) ?? Date()
        return PersistedStagedProposal(
            id: row["id"],
            createdAt: date,
            rung: row["rung"],
            prompt: row["prompt"],
            output: row["output"],
            egressSummary: row["egress"],
            state: row["state"]
        )
    }
}
