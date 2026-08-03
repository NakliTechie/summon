import Foundation
import GRDB

/// Pinned commands / results (RC-46).
public struct FavoriteItem: Sendable, Hashable, Codable, Equatable, Identifiable {
    public let id: String
    public let resultID: String
    public let title: String
    public let kind: String
    public let path: String?

    public init(
        id: String = UUID().uuidString,
        resultID: String,
        title: String,
        kind: String,
        path: String? = nil
    ) {
        self.id = id
        self.resultID = resultID
        self.title = title
        self.kind = kind
        self.path = path
    }
}

public struct FavoriteStore: Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS favorites (
                    id TEXT PRIMARY KEY NOT NULL,
                    result_id TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    path TEXT
                );
                """)
        }
    }

    public func add(_ item: FavoriteItem) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO favorites (id, result_id, title, kind, path)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(result_id) DO UPDATE SET title = excluded.title
                    """,
                arguments: [item.id, item.resultID, item.title, item.kind, item.path]
            )
        }
    }

    public func remove(resultID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM favorites WHERE result_id = ?", arguments: [resultID])
        }
    }

    public func all() throws -> [FavoriteItem] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM favorites ORDER BY title")
            return rows.map {
                FavoriteItem(
                    id: $0["id"],
                    resultID: $0["result_id"],
                    title: $0["title"],
                    kind: $0["kind"],
                    path: $0["path"]
                )
            }
        }
    }

    public func contains(resultID: String) throws -> Bool {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM favorites WHERE result_id = ?",
                arguments: [resultID]
            ) != nil
        }
    }
}
