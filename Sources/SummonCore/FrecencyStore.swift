import Foundation
import GRDB

/// Usage ranking for top-hit / recents (SP-19, SP-24). Local only.
public struct FrecencyEntry: Sendable, Hashable, Codable, Equatable {
    public let resultID: String
    public var count: Int
    public var lastUsed: Date
    public var title: String
    public var kind: String
    public var path: String?
    public var payload: [String: JSONValue]

    public init(
        resultID: String,
        count: Int,
        lastUsed: Date,
        title: String,
        kind: String,
        path: String? = nil,
        payload: [String: JSONValue] = [:]
    ) {
        self.resultID = resultID
        self.count = count
        self.lastUsed = lastUsed
        self.title = title
        self.kind = kind
        self.path = path
        self.payload = payload
    }

    /// Higher = more preferred. Half-life ~7 days.
    public func score(now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(lastUsed) / 86_400)
        let recency = pow(0.5, days / 7.0)
        return Double(count) * recency
    }
}

public struct FrecencyStore: Sendable {
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
                CREATE TABLE IF NOT EXISTS frecency (
                    result_id TEXT PRIMARY KEY NOT NULL,
                    count INTEGER NOT NULL DEFAULT 0,
                    last_used TEXT NOT NULL,
                    title TEXT NOT NULL,
                    kind TEXT NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS frecency_snapshots (
                    result_id TEXT PRIMARY KEY NOT NULL,
                    path TEXT,
                    payload_json TEXT NOT NULL
                );
                """)
        }
    }

    public func record(
        resultID: String,
        title: String,
        kind: String,
        path: String? = nil,
        payload: [String: JSONValue] = [:],
        at date: Date = Date()
    ) throws {
        try dbQueue.write { db in
            try record(
                resultID: resultID,
                title: title,
                kind: kind,
                path: path,
                payload: payload,
                at: date,
                in: db
            )
        }
    }

    func record(
        resultID: String,
        title: String,
        kind: String,
        path: String? = nil,
        payload: [String: JSONValue] = [:],
        at date: Date = Date(),
        in db: Database
    ) throws {
        let payloadJSON = try Self.encodePayload(payload)
        if let row = try Row.fetchOne(
                db,
                sql: "SELECT count FROM frecency WHERE result_id = ?",
                arguments: [resultID]
            ) {
                let count = (row["count"] as Int) + 1
                try db.execute(
                    sql: """
                        UPDATE frecency SET count = ?, last_used = ?, title = ?, kind = ?
                        WHERE result_id = ?
                        """,
                    arguments: [count, Self.iso.string(from: date), title, kind, resultID]
                )
        } else {
            try db.execute(
                sql: """
                    INSERT INTO frecency (result_id, count, last_used, title, kind)
                    VALUES (?, 1, ?, ?, ?)
                    """,
                arguments: [resultID, Self.iso.string(from: date), title, kind]
            )
        }
        try db.execute(
            sql: """
                INSERT INTO frecency_snapshots (result_id, path, payload_json)
                VALUES (?, ?, ?)
                ON CONFLICT(result_id) DO UPDATE SET
                    path = excluded.path,
                    payload_json = excluded.payload_json
                """,
            arguments: [resultID, path, payloadJSON]
        )
    }

    func restore(_ entry: FrecencyEntry, in db: Database) throws {
        guard !entry.resultID.isEmpty, entry.count > -1 else {
            throw CoreError.store("restored frecency requires an id and non-negative count")
        }
        let payloadJSON = try Self.encodePayload(entry.payload)
        try db.execute(
            sql: """
                INSERT INTO frecency (result_id, count, last_used, title, kind)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(result_id) DO UPDATE SET
                    count = excluded.count,
                    last_used = excluded.last_used,
                    title = excluded.title,
                    kind = excluded.kind
                """,
            arguments: [
                entry.resultID,
                entry.count,
                Self.iso.string(from: entry.lastUsed),
                entry.title,
                entry.kind,
            ]
        )
        try db.execute(
            sql: """
                INSERT INTO frecency_snapshots (result_id, path, payload_json)
                VALUES (?, ?, ?)
                ON CONFLICT(result_id) DO UPDATE SET
                    path = excluded.path,
                    payload_json = excluded.payload_json
                """,
            arguments: [entry.resultID, entry.path, payloadJSON]
        )
    }

    func all(in db: Database) throws -> [FrecencyEntry] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT f.*, s.path, s.payload_json
                FROM frecency AS f
                LEFT JOIN frecency_snapshots AS s ON s.result_id = f.result_id
                ORDER BY f.result_id
                """
        )
        return rows.map {
            FrecencyEntry(
                resultID: $0["result_id"],
                count: $0["count"],
                lastUsed: Self.iso.date(from: $0["last_used"]) ?? Date.distantPast,
                title: $0["title"],
                kind: $0["kind"],
                path: $0["path"],
                payload: Self.decodePayload($0["payload_json"])
            )
        }
    }

    public func boost(for resultID: String) throws -> Double {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM frecency WHERE result_id = ?",
                arguments: [resultID]
            ) else { return 0 }
            let entry = FrecencyEntry(
                resultID: row["result_id"],
                count: row["count"],
                lastUsed: Self.iso.date(from: row["last_used"]) ?? Date.distantPast,
                title: row["title"],
                kind: row["kind"]
            )
            return entry.score()
        }
    }

    public func recents(limit: Int = 10) throws -> [FrecencyEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT f.*, s.path, s.payload_json
                    FROM frecency AS f
                    LEFT JOIN frecency_snapshots AS s ON s.result_id = f.result_id
                    ORDER BY f.last_used DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
            return rows.map {
                FrecencyEntry(
                    resultID: $0["result_id"],
                    count: $0["count"],
                    lastUsed: Self.iso.date(from: $0["last_used"]) ?? Date.distantPast,
                    title: $0["title"],
                    kind: $0["kind"],
                    path: $0["path"],
                    payload: Self.decodePayload($0["payload_json"])
                )
            }
        }
    }

    private static func encodePayload(_ payload: [String: JSONValue]) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CoreError.store("frecency payload encoding failed")
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
