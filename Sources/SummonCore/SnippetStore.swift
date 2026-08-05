import Foundation
import GRDB

public struct Snippet: Sendable, Hashable, Codable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var body: String
    public var keyword: String?

    public init(id: String = UUID().uuidString, name: String, body: String, keyword: String? = nil) {
        self.id = id
        self.name = name
        self.body = body
        self.keyword = keyword
    }
}

public struct SnippetStore: Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func upsert(_ snippet: Snippet) throws {
        try dbQueue.write { db in
            try upsert(snippet, in: db)
        }
    }

    func upsert(_ snippet: Snippet, in db: Database) throws {
        guard !snippet.name.isEmpty else {
            throw CoreError.store("snippet name must be non-empty")
        }
        try db.execute(
            sql: """
                INSERT INTO snippets (id, name, body, keyword)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  body = excluded.body,
                  keyword = excluded.keyword
                """,
            arguments: [snippet.id, snippet.name, snippet.body, snippet.keyword]
        )
    }

    public func delete(id: String) throws {
        try dbQueue.write { db in
            try delete(id: id, in: db)
        }
    }

    func delete(id: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM snippets WHERE id = ?", arguments: [id])
    }

    public func get(id: String) throws -> Snippet? {
        try dbQueue.read { db in
            try get(id: id, in: db)
        }
    }

    func get(id: String, in db: Database) throws -> Snippet? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM snippets WHERE id = ?",
            arguments: [id]
        ) else { return nil }
        return Self.snippet(from: row)
    }

    public func all() throws -> [Snippet] {
        try dbQueue.read { db in
            try all(in: db)
        }
    }

    func all(in db: Database) throws -> [Snippet] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM snippets ORDER BY name COLLATE NOCASE ASC")
        return rows.map(Self.snippet(from:))
    }

    public func search(query: FilterQuery, limit: Int = 50) throws -> [SearchResult] {
        let all = try all()
        let free = query.freeText.lowercased()
        let filtered: [Snippet]
        if free.isEmpty {
            filtered = Array(all.prefix(limit))
        } else {
            filtered = all.filter {
                $0.name.lowercased().contains(free)
                    || $0.body.lowercased().contains(free)
                    || ($0.keyword?.lowercased().contains(free) ?? false)
            }.prefix(limit).map { $0 }
        }
        return filtered.enumerated().map { index, snip in
            SearchResult(
                id: "snippet:\(snip.id)",
                title: snip.name,
                subtitle: snip.keyword ?? String(snip.body.prefix(60)),
                kind: .snippet,
                score: Double(800 - index),
                payload: [
                    "snippetID": .string(snip.id),
                    "body": .string(snip.body),
                ]
            )
        }
    }

    private static func snippet(from row: Row) -> Snippet {
        Snippet(
            id: row["id"],
            name: row["name"],
            body: row["body"],
            keyword: row["keyword"]
        )
    }
}
