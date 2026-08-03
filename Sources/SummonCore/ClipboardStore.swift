import Foundation
import GRDB

public struct ClipboardItem: Sendable, Hashable, Codable, Equatable, Identifiable {
    public let id: String
    public var text: String
    public var sourceApp: String?
    public var createdAt: Date
    public var isPinned: Bool

    public init(
        id: String = UUID().uuidString,
        text: String,
        sourceApp: String? = nil,
        createdAt: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.text = text
        self.sourceApp = sourceApp
        self.createdAt = createdAt
        self.isPinned = isPinned
    }
}

public struct ClipboardStore: Sendable {
    private let dbQueue: DatabaseQueue
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func ingest(_ item: ClipboardItem) throws {
        guard !item.text.isEmpty else {
            throw CoreError.store("clipboard text must be non-empty")
        }
        // De-dupe: if same text as latest unpinned, bump timestamp instead of insert.
        try dbQueue.write { db in
            if let latest = try Row.fetchOne(
                db,
                sql: "SELECT id, text FROM clipboard_items ORDER BY created_at DESC LIMIT 1"
            ),
               (latest["text"] as String) == item.text {
                try db.execute(
                    sql: "UPDATE clipboard_items SET created_at = ? WHERE id = ?",
                    arguments: [Self.iso.string(from: item.createdAt), latest["id"] as String]
                )
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO clipboard_items (id, text, source_app, created_at, is_pinned)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    item.id,
                    item.text,
                    item.sourceApp,
                    Self.iso.string(from: item.createdAt),
                    item.isPinned ? 1 : 0,
                ]
            )
        }
    }

    public func delete(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM clipboard_items WHERE id = ?", arguments: [id])
        }
    }

    public func setPinned(id: String, pinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET is_pinned = ? WHERE id = ?",
                arguments: [pinned ? 1 : 0, id]
            )
        }
    }

    public func clearUnpinned() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM clipboard_items WHERE is_pinned = 0")
        }
    }

    public func get(id: String) throws -> ClipboardItem? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM clipboard_items WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return try Self.item(from: row)
        }
    }

    public func all(limit: Int = 500) throws -> [ClipboardItem] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM clipboard_items
                    ORDER BY is_pinned DESC, created_at DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
            return try rows.map { try Self.item(from: $0) }
        }
    }

    public func search(query: FilterQuery, limit: Int = 50) throws -> [SearchResult] {
        let free = query.freeText.lowercased()
        let items = try all(limit: 500)
        let filtered: [ClipboardItem]
        if free.isEmpty {
            filtered = Array(items.prefix(limit))
        } else {
            filtered = items.filter { $0.text.lowercased().contains(free) }.prefix(limit).map { $0 }
        }
        return filtered.enumerated().map { index, item in
            let preview = item.text
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(80)
            return SearchResult(
                id: "clipboard:\(item.id)",
                title: String(preview),
                subtitle: item.sourceApp ?? (item.isPinned ? "Pinned" : nil),
                kind: .clipboard,
                score: Double((item.isPinned ? 950 : 850) - index),
                payload: [
                    "clipboardID": .string(item.id),
                    "text": .string(item.text),
                    "pinned": .bool(item.isPinned),
                ]
            )
        }
    }

    private static func item(from row: Row) throws -> ClipboardItem {
        let ts: String = row["created_at"]
        guard let date = iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) else {
            throw CoreError.store("clipboard bad timestamp \(ts)")
        }
        let pinned: Int = row["is_pinned"]
        return ClipboardItem(
            id: row["id"],
            text: row["text"],
            sourceApp: row["source_app"],
            createdAt: date,
            isPinned: pinned != 0
        )
    }
}
