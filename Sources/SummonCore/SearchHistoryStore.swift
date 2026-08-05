import Foundation
import GRDB

/// Command / search history (RC-54). Distinct from frecency.
public struct SearchHistoryEntry: Sendable, Hashable, Codable, Equatable, Identifiable {
    public let id: String
    public let query: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, query: String, createdAt: Date = Date()) {
        self.id = id
        self.query = query
        self.createdAt = createdAt
    }
}

public struct SearchHistoryStore: Sendable {
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
                CREATE TABLE IF NOT EXISTS search_history (
                    id TEXT PRIMARY KEY NOT NULL,
                    query TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS search_history_created_idx
                ON search_history(created_at DESC);
                """)
        }
    }

    public func record(_ query: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try record(query, id: UUID().uuidString, at: date, in: db)
        }
    }

    func record(
        _ query: String,
        id: String,
        at date: Date = Date(),
        in db: Database
    ) throws {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        try db.execute(
            sql: "INSERT INTO search_history (id, query, created_at) VALUES (?, ?, ?)",
            arguments: [id, normalized, Self.iso.string(from: date)]
        )
        try db.execute(sql: """
            DELETE FROM search_history WHERE id NOT IN (
                SELECT id FROM search_history ORDER BY created_at DESC LIMIT 200
            )
            """)
    }

    func restore(_ entry: SearchHistoryEntry, in db: Database) throws {
        let query = entry.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.id.isEmpty, !query.isEmpty else {
            throw CoreError.store("restored history requires an id and query")
        }
        try db.execute(
            sql: """
                INSERT INTO search_history (id, query, created_at)
                VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    query = excluded.query,
                    created_at = excluded.created_at
                """,
            arguments: [entry.id, query, Self.iso.string(from: entry.createdAt)]
        )
    }

    func all(in db: Database) throws -> [SearchHistoryEntry] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM search_history ORDER BY created_at DESC, id"
        )
        return rows.map {
            SearchHistoryEntry(
                id: $0["id"],
                query: $0["query"],
                createdAt: Self.iso.date(from: $0["created_at"]) ?? Date.distantPast
            )
        }
    }

    public func recent(limit: Int = 20) throws -> [SearchHistoryEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM search_history ORDER BY created_at DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.map {
                SearchHistoryEntry(
                    id: $0["id"],
                    query: $0["query"],
                    createdAt: Self.iso.date(from: $0["created_at"]) ?? Date.distantPast
                )
            }
        }
    }
}
