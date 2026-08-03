import Foundation
import GRDB

/// Usage ranking for top-hit / recents (SP-19, SP-24). Local only.
public struct FrecencyEntry: Sendable, Hashable, Codable, Equatable {
    public let resultID: String
    public var count: Int
    public var lastUsed: Date
    public var title: String
    public var kind: String

    public init(resultID: String, count: Int, lastUsed: Date, title: String, kind: String) {
        self.resultID = resultID
        self.count = count
        self.lastUsed = lastUsed
        self.title = title
        self.kind = kind
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
        }
    }

    public func record(resultID: String, title: String, kind: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
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
                sql: "SELECT * FROM frecency ORDER BY last_used DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.map {
                FrecencyEntry(
                    resultID: $0["result_id"],
                    count: $0["count"],
                    lastUsed: Self.iso.date(from: $0["last_used"]) ?? Date.distantPast,
                    title: $0["title"],
                    kind: $0["kind"]
                )
            }
        }
    }
}
