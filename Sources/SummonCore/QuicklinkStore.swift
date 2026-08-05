import Foundation
import GRDB

public struct Quicklink: Sendable, Hashable, Codable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var url: String
    public var keyword: String?

    public init(id: String = UUID().uuidString, name: String, url: String, keyword: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.keyword = keyword
    }
}

public struct QuicklinkStore: Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func upsert(_ link: Quicklink) throws {
        try dbQueue.write { db in
            try upsert(link, in: db)
        }
    }

    func upsert(_ link: Quicklink, in db: Database) throws {
        guard !link.name.isEmpty else { throw CoreError.store("quicklink name must be non-empty") }
        try Self.validateURL(link.url)
        try db.execute(
            sql: """
                INSERT INTO quicklinks (id, name, url, keyword)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  url = excluded.url,
                  keyword = excluded.keyword
                """,
            arguments: [link.id, link.name, link.url, link.keyword]
        )
    }

    public func delete(id: String) throws {
        try dbQueue.write { db in
            try delete(id: id, in: db)
        }
    }

    func delete(id: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM quicklinks WHERE id = ?", arguments: [id])
    }

    public func get(id: String) throws -> Quicklink? {
        try dbQueue.read { db in
            try get(id: id, in: db)
        }
    }

    func get(id: String, in db: Database) throws -> Quicklink? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM quicklinks WHERE id = ?",
            arguments: [id]
        ) else { return nil }
        return Quicklink(
            id: row["id"],
            name: row["name"],
            url: row["url"],
            keyword: row["keyword"]
        )
    }

    public static func validateURL(_ raw: String) throws {
        guard raw.utf8.count <= SchemaGate.maximumURLBytes else {
            throw CoreError.schemaValidation("quicklink url exceeds byte limit")
        }
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else {
            throw CoreError.schemaValidation("quicklink url requires an absolute http or https URL")
        }
    }

    public func all() throws -> [Quicklink] {
        try dbQueue.read { db in
            try all(in: db)
        }
    }

    func all(in db: Database) throws -> [Quicklink] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM quicklinks ORDER BY name COLLATE NOCASE ASC")
        return rows.map {
            Quicklink(id: $0["id"], name: $0["name"], url: $0["url"], keyword: $0["keyword"])
        }
    }

    public func search(query: FilterQuery, limit: Int = 50) throws -> [SearchResult] {
        let free = query.freeText.lowercased()
        let links = try all()
        let filtered: [Quicklink]
        if free.isEmpty {
            filtered = Array(links.prefix(limit))
        } else {
            filtered = links.filter {
                $0.name.lowercased().contains(free)
                    || $0.url.lowercased().contains(free)
                    || ($0.keyword?.lowercased().contains(free) ?? false)
            }.prefix(limit).map { $0 }
        }
        return filtered.enumerated().map { index, link in
            SearchResult(
                id: "quicklink:\(link.id)",
                title: link.name,
                subtitle: link.url,
                kind: .quicklink,
                path: link.url,
                score: Double(820 - index),
                payload: [
                    "quicklinkID": .string(link.id),
                    "url": .string(link.url),
                ]
            )
        }
    }
}
