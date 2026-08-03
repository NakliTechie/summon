import Foundation
import GRDB

/// S2 full-text index (FTS5). Opt-in, rebuildable, consent-gated at product level.
public struct FTSDocument: Sendable, Hashable, Equatable {
    public let id: String
    public let title: String
    public let body: String
    public let path: String?

    public init(id: String, title: String, body: String, path: String? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.path = path
    }
}

public struct FTSIndex: Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Ensure FTS tables exist (idempotent migration helper for tests).
    public func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS fts_docs USING fts5(
                    id UNINDEXED,
                    title,
                    body,
                    path UNINDEXED,
                    tokenize = 'porter unicode61'
                );
                """)
        }
    }

    public func clear() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM fts_docs")
        }
    }

    public func upsert(_ doc: FTSDocument) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM fts_docs WHERE id = ?", arguments: [doc.id])
            try db.execute(
                sql: "INSERT INTO fts_docs (id, title, body, path) VALUES (?, ?, ?, ?)",
                arguments: [doc.id, doc.title, doc.body, doc.path]
            )
        }
    }

    public func search(query: String, limit: Int = 50) throws -> [FTSDocument] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return try dbQueue.read { db in
            // MATCH with simple phrase; escape quotes
            let escaped = q.replacingOccurrences(of: "\"", with: "")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title, body, path FROM fts_docs
                    WHERE fts_docs MATCH ?
                    LIMIT ?
                    """,
                arguments: [escaped, limit]
            )
            return rows.map {
                FTSDocument(
                    id: $0["id"],
                    title: $0["title"],
                    body: $0["body"],
                    path: $0["path"]
                )
            }
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM fts_docs") ?? 0
        }
    }
}
