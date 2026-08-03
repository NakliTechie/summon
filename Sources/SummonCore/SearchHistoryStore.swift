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
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO search_history (id, query, created_at) VALUES (?, ?, ?)",
                arguments: [UUID().uuidString, q, Self.iso.string(from: date)]
            )
            // Cap at 200 rows
            try db.execute(sql: """
                DELETE FROM search_history WHERE id NOT IN (
                    SELECT id FROM search_history ORDER BY created_at DESC LIMIT 200
                )
                """)
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
