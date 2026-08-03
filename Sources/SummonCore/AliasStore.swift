import Foundation
import GRDB

/// Learned Quick Keys / user aliases (SP-16, RC-45).
public struct LearnedAlias: Sendable, Hashable, Codable, Equatable, Identifiable {
    public var id: String { keyword }
    public let keyword: String
    public let targetResultID: String
    public let title: String
    public let kind: String

    public init(keyword: String, targetResultID: String, title: String, kind: String) {
        self.keyword = keyword
        self.targetResultID = targetResultID
        self.title = title
        self.kind = kind
    }
}

public struct AliasStore: Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS learned_aliases (
                    keyword TEXT PRIMARY KEY NOT NULL,
                    target_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    kind TEXT NOT NULL
                );
                """)
        }
    }

    public func set(_ alias: LearnedAlias) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learned_aliases (keyword, target_id, title, kind)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(keyword) DO UPDATE SET
                        target_id = excluded.target_id,
                        title = excluded.title,
                        kind = excluded.kind
                    """,
                arguments: [alias.keyword.lowercased(), alias.targetResultID, alias.title, alias.kind]
            )
        }
    }

    public func get(keyword: String) throws -> LearnedAlias? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM learned_aliases WHERE keyword = ?",
                arguments: [keyword.lowercased()]
            ) else { return nil }
            return LearnedAlias(
                keyword: row["keyword"],
                targetResultID: row["target_id"],
                title: row["title"],
                kind: row["kind"]
            )
        }
    }

    public func all() throws -> [LearnedAlias] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM learned_aliases ORDER BY keyword")
            return rows.map {
                LearnedAlias(
                    keyword: $0["keyword"],
                    targetResultID: $0["target_id"],
                    title: $0["title"],
                    kind: $0["kind"]
                )
            }
        }
    }

    public func delete(keyword: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM learned_aliases WHERE keyword = ?", arguments: [keyword.lowercased()])
        }
    }
}
