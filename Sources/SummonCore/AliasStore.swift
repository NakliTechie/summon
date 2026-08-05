import Foundation
import GRDB

/// Learned Quick Keys / user aliases (SP-16, RC-45).
public struct LearnedAlias: Sendable, Hashable, Codable, Equatable, Identifiable {
    public var id: String { keyword }
    public let keyword: String
    public let targetResultID: String
    public let title: String
    public let kind: String
    public let path: String?
    public let payload: [String: JSONValue]?

    public init(
        keyword: String,
        targetResultID: String,
        title: String,
        kind: String,
        path: String? = nil,
        payload: [String: JSONValue]? = nil
    ) {
        self.keyword = keyword
        self.targetResultID = targetResultID
        self.title = title
        self.kind = kind
        self.path = path
        self.payload = payload
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
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS learned_alias_snapshots (
                    keyword TEXT PRIMARY KEY NOT NULL,
                    path TEXT,
                    payload_json TEXT NOT NULL
                );
                """)
        }
    }

    public func set(_ alias: LearnedAlias) throws {
        try dbQueue.write { db in
            try set(alias, in: db)
        }
    }

    func set(_ alias: LearnedAlias, in db: Database) throws {
        guard !alias.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreError.store("alias keyword must be non-empty")
        }
        guard !alias.targetResultID.isEmpty else {
            throw CoreError.store("alias target must be non-empty")
        }
        let payloadJSON = try Self.encodePayload(alias.payload ?? [:])
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
        try db.execute(
            sql: """
                INSERT INTO learned_alias_snapshots (keyword, path, payload_json)
                VALUES (?, ?, ?)
                ON CONFLICT(keyword) DO UPDATE SET
                    path = excluded.path,
                    payload_json = excluded.payload_json
                """,
            arguments: [alias.keyword.lowercased(), alias.path, payloadJSON]
        )
    }

    public func get(keyword: String) throws -> LearnedAlias? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT a.*, s.path, s.payload_json
                    FROM learned_aliases AS a
                    LEFT JOIN learned_alias_snapshots AS s ON s.keyword = a.keyword
                    WHERE a.keyword = ?
                    """,
                arguments: [keyword.lowercased()]
            ) else { return nil }
            return LearnedAlias(
                keyword: row["keyword"],
                targetResultID: row["target_id"],
                title: row["title"],
                kind: row["kind"],
                path: row["path"],
                payload: Self.decodePayload(row["payload_json"])
            )
        }
    }

    public func all() throws -> [LearnedAlias] {
        try dbQueue.read { db in
            try all(in: db)
        }
    }

    func all(in db: Database) throws -> [LearnedAlias] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT a.*, s.path, s.payload_json
                FROM learned_aliases AS a
                LEFT JOIN learned_alias_snapshots AS s ON s.keyword = a.keyword
                ORDER BY a.keyword
                """
        )
        return rows.map {
            LearnedAlias(
                keyword: $0["keyword"],
                targetResultID: $0["target_id"],
                title: $0["title"],
                kind: $0["kind"],
                path: $0["path"],
                payload: Self.decodePayload($0["payload_json"])
            )
        }
    }

    public func delete(keyword: String) throws {
        try dbQueue.write { db in
            try delete(keyword: keyword, in: db)
        }
    }

    func delete(keyword: String, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM learned_alias_snapshots WHERE keyword = ?",
            arguments: [keyword.lowercased()]
        )
        try db.execute(
            sql: "DELETE FROM learned_aliases WHERE keyword = ?",
            arguments: [keyword.lowercased()]
        )
    }

    private static func encodePayload(_ payload: [String: JSONValue]) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CoreError.store("alias payload encoding failed")
        }
        return text
    }

    private static func decodePayload(_ text: String?) -> [String: JSONValue] {
        guard let text,
              let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return [:]
        }
        return payload
    }
}
