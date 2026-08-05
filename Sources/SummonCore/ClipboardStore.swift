import Foundation
import CryptoKit
import GRDB

public enum ClipboardContentKind: String, Sendable, Hashable, Codable, Equatable {
    case plainText
    case richText
    case image
}

public struct ClipboardItem: Sendable, Hashable, Codable, Equatable, Identifiable {
    public let id: String
    public var text: String
    public var sourceApp: String?
    public var createdAt: Date
    public var isPinned: Bool
    public var contentKind: ClipboardContentKind
    public var flavor: String?
    public var data: Data?

    public init(
        id: String = UUID().uuidString,
        text: String,
        sourceApp: String? = nil,
        createdAt: Date = Date(),
        isPinned: Bool = false,
        contentKind: ClipboardContentKind = .plainText,
        flavor: String? = nil,
        data: Data? = nil
    ) {
        self.id = id
        self.text = text
        self.sourceApp = sourceApp
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.contentKind = contentKind
        self.flavor = flavor
        self.data = data
    }

    /// Paste-as-plain: strip RTF/HTML markers already stored as plain text; NFC normalize.
    public var plainText: String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    public var displayText: String {
        if !text.isEmpty { return text }
        switch contentKind {
        case .plainText: return "Text"
        case .richText: return "Rich Text"
        case .image: return "Image"
        }
    }

    public var contentHash: String {
        var bytes = Data(contentKind.rawValue.utf8)
        bytes.append(0)
        if let flavor {
            bytes.append(contentsOf: flavor.utf8)
        }
        bytes.append(0)
        if let data {
            bytes.append(data)
        } else {
            bytes.append(contentsOf: text.utf8)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Payload-free row used by bounded history and search pages.
public struct ClipboardItemSummary: Sendable, Hashable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let sourceApp: String?
    public let createdAt: Date
    public let isPinned: Bool
    public let contentKind: ClipboardContentKind
    public let flavor: String?

    public var displayText: String {
        if !text.isEmpty { return text }
        switch contentKind {
        case .plainText: return "Text"
        case .richText: return "Rich Text"
        case .image: return "Image"
        }
    }
}

public struct ClipboardStore: Sendable {
    private let dbQueue: DatabaseQueue
    public static let defaultUnpinnedRetentionLimit = 500
    public static let maximumPayloadBytes = 25 * 1_024 * 1_024
    private let unpinnedRetentionLimit: Int
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(
        dbQueue: DatabaseQueue,
        unpinnedRetentionLimit: Int = Self.defaultUnpinnedRetentionLimit
    ) {
        self.dbQueue = dbQueue
        self.unpinnedRetentionLimit = max(0, unpinnedRetentionLimit)
    }

    public func ingest(_ item: ClipboardItem) throws {
        try dbQueue.write { db in
            try ingest(item, in: db)
        }
    }

    func ingest(_ item: ClipboardItem, in db: Database) throws {
        try Self.validate(item)
        // Replace matching unpinned rows with the incoming identity. The action
        // journal then carries the same identity as the retained store row.
        let duplicateIDs = try String.fetchAll(
            db,
            sql: "SELECT id FROM clipboard_items WHERE content_hash = ? AND is_pinned = 0 AND id != ?",
            arguments: [item.contentHash, item.id]
        )
        if !duplicateIDs.isEmpty {
            try Self.scrubRetainedPayloads(db, clipboardIDs: Set(duplicateIDs))
            for id in duplicateIDs {
                try db.execute(
                    sql: "DELETE FROM clipboard_items WHERE id = ?",
                    arguments: [id]
                )
            }
        }
        if try Row.fetchOne(
            db,
            sql: "SELECT 1 FROM clipboard_items WHERE id = ?",
            arguments: [item.id]
        ) != nil {
            try db.execute(
                sql: """
                    UPDATE clipboard_items
                    SET text = ?, source_app = ?, created_at = ?, is_pinned = ?,
                        content_kind = ?, flavor = ?, payload = ?, content_hash = ?
                    WHERE id = ?
                    """,
                arguments: [
                    item.text,
                    item.sourceApp,
                    Self.iso.string(from: item.createdAt),
                    item.isPinned ? 1 : 0,
                    item.contentKind.rawValue,
                    item.flavor,
                    item.data,
                    item.contentHash,
                    item.id,
                ]
            )
            try pruneUnpinnedIfNeeded(db)
            return
        }
        try db.execute(
            sql: """
                INSERT INTO clipboard_items (
                    id, text, source_app, created_at, is_pinned,
                    content_kind, flavor, payload, content_hash
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                item.id,
                item.text,
                item.sourceApp,
                Self.iso.string(from: item.createdAt),
                item.isPinned ? 1 : 0,
                item.contentKind.rawValue,
                item.flavor,
                item.data,
                item.contentHash,
            ]
        )
        try pruneUnpinnedIfNeeded(db)
    }

    public func delete(id: String) throws {
        try dbQueue.write { db in
            try delete(id: id, in: db)
        }
    }

    func delete(id: String, in db: Database) throws {
        try Self.scrubRetainedPayloads(db, clipboardIDs: [id])
        try db.execute(sql: "DELETE FROM clipboard_items WHERE id = ?", arguments: [id])
    }

    public func setPinned(id: String, pinned: Bool) throws {
        try dbQueue.write { db in
            try setPinned(id: id, pinned: pinned, in: db)
        }
    }

    func setPinned(id: String, pinned: Bool, in db: Database) throws {
        try db.execute(
            sql: "UPDATE clipboard_items SET is_pinned = ? WHERE id = ?",
            arguments: [pinned ? 1 : 0, id]
        )
        if !pinned {
            try pruneUnpinnedIfNeeded(db)
        }
    }

    public func touch(id: String, createdAt: Date) throws {
        try dbQueue.write { db in
            try touch(id: id, createdAt: createdAt, in: db)
        }
    }

    func touch(id: String, createdAt: Date, in db: Database) throws {
        try db.execute(
            sql: "UPDATE clipboard_items SET created_at = ? WHERE id = ?",
            arguments: [Self.iso.string(from: createdAt), id]
        )
    }

    public func clearUnpinned() throws {
        try dbQueue.write { db in
            try clearUnpinned(in: db)
        }
    }

    func clearUnpinned(in db: Database) throws {
        let ids = try String.fetchAll(
            db,
            sql: "SELECT id FROM clipboard_items WHERE is_pinned = 0"
        )
        try Self.scrubRetainedPayloads(db, clipboardIDs: Set(ids))
        try db.execute(sql: "DELETE FROM clipboard_items WHERE is_pinned = 0")
    }

    func clearAll(in db: Database) throws {
        let ids = try String.fetchAll(db, sql: "SELECT id FROM clipboard_items")
        try Self.scrubRetainedPayloads(db, clipboardIDs: Set(ids))
        try db.execute(sql: "DELETE FROM clipboard_items")
    }

    public func get(id: String) throws -> ClipboardItem? {
        return try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM clipboard_items WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return try Self.item(from: row)
        }
    }

    public func all(limit: Int = 50) throws -> [ClipboardItem] {
        guard limit > 0 else { return [] }
        return try dbQueue.read { db in
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

    /// Exhaustive payload access for explicit clipboard-inclusive snapshots only.
    func snapshotItems() throws -> [ClipboardItem] {
        try dbQueue.read { db in
            try snapshotItems(in: db)
        }
    }

    func snapshotItems(in db: Database) throws -> [ClipboardItem] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM clipboard_items
                ORDER BY is_pinned DESC, created_at DESC
                """
        )
        return try rows.map { try Self.item(from: $0) }
    }

    /// Returns at most `perBucketLimit` pinned and unpinned rows without BLOB payloads.
    public func metadataPage(perBucketLimit: Int = 500) throws -> [ClipboardItemSummary] {
        guard perBucketLimit > 0 else { return [] }
        return try dbQueue.read { db in
            let pinnedRows = try Self.fetchSummaryRows(
                db,
                pinned: true,
                query: nil,
                limit: perBucketLimit
            )
            let unpinnedRows = try Self.fetchSummaryRows(
                db,
                pinned: false,
                query: nil,
                limit: perBucketLimit
            )
            return try (pinnedRows + unpinnedRows).map { try Self.summary(from: $0) }
        }
    }

    public func matchingMetadataPage(
        _ query: String,
        perBucketLimit: Int = 500
    ) throws -> [ClipboardItemSummary] {
        guard perBucketLimit > 0 else { return [] }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return try metadataPage(perBucketLimit: perBucketLimit) }
        return try dbQueue.read { db in
            let pinnedRows = try Self.fetchSummaryRows(
                db,
                pinned: true,
                query: normalized,
                limit: perBucketLimit
            )
            let unpinnedRows = try Self.fetchSummaryRows(
                db,
                pinned: false,
                query: normalized,
                limit: perBucketLimit
            )
            return try (pinnedRows + unpinnedRows).map { try Self.summary(from: $0) }
        }
    }

    public func search(query: FilterQuery, limit: Int = 50) throws -> [SearchResult] {
        guard limit > 0 else { return [] }
        let free = query.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = free.isEmpty
            ? try metadataPage(perBucketLimit: limit)
            : try matchingMetadataPage(free, perBucketLimit: limit)
        let filtered = Self.balancedSummaries(matches, limit: limit)
        return filtered.enumerated().map { index, item in
            let preview = item.displayText
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(80)
            var payload: [String: JSONValue] = [
                "clipboardID": .string(item.id),
                "text": .string(item.text),
                "pinned": .bool(item.isPinned),
                "contentKind": .string(item.contentKind.rawValue),
            ]
            if let flavor = item.flavor {
                payload["flavor"] = .string(flavor)
            }
            return SearchResult(
                id: "clipboard:\(item.id)",
                title: String(preview),
                subtitle: item.sourceApp ?? (item.isPinned ? "Pinned" : nil),
                kind: .clipboard,
                score: Double((item.isPinned ? 950 : 850) - index),
                payload: payload
            )
        }
    }

    private static func balancedSummaries(
        _ matches: [ClipboardItemSummary],
        limit: Int
    ) -> [ClipboardItemSummary] {
        let pinned = matches.filter(\.isPinned)
        let unpinned = matches.filter { !$0.isPinned }
        let pinnedBudget = unpinned.isEmpty ? limit : max(1, limit / 2)
        let selectedPinned = Array(pinned.prefix(pinnedBudget))
        let selectedUnpinned = Array(unpinned.prefix(limit - selectedPinned.count))
        let remaining = max(0, limit - selectedPinned.count - selectedUnpinned.count)
        return selectedPinned
            + selectedUnpinned
            + Array(pinned.dropFirst(selectedPinned.count).prefix(remaining))
    }

    private static func fetchSummaryRows(
        _ db: Database,
        pinned: Bool,
        query: String?,
        limit: Int
    ) throws -> [Row] {
        var sql = """
            SELECT id, text, source_app, created_at, is_pinned, content_kind, flavor
            FROM clipboard_items
            WHERE is_pinned = ?
            """
        var arguments: [DatabaseValueConvertible?] = [pinned ? 1 : 0]
        if let query {
            sql += """

              AND (
                instr(lower(
                    CASE
                        WHEN text != '' THEN text
                        WHEN content_kind = 'image' THEN 'Image'
                        WHEN content_kind = 'richText' THEN 'Rich Text'
                        ELSE 'Text'
                    END
                ), ?) > 0
                OR instr(lower(COALESCE(source_app, '')), ?) > 0
              )
            """
            arguments.append(query)
            arguments.append(query)
        }
        sql += "\nORDER BY created_at DESC\nLIMIT ?"
        arguments.append(limit)
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
    }

    private static func summary(from row: Row) throws -> ClipboardItemSummary {
        let ts: String = row["created_at"]
        guard let date = iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) else {
            throw CoreError.store("clipboard bad timestamp \(ts)")
        }
        let pinned: Int = row["is_pinned"]
        let kindRaw: String = row["content_kind"]
        guard let contentKind = ClipboardContentKind(rawValue: kindRaw) else {
            throw CoreError.store("clipboard bad content kind \(kindRaw)")
        }
        return ClipboardItemSummary(
            id: row["id"],
            text: row["text"],
            sourceApp: row["source_app"],
            createdAt: date,
            isPinned: pinned != 0,
            contentKind: contentKind,
            flavor: row["flavor"]
        )
    }

    private static func item(from row: Row) throws -> ClipboardItem {
        let ts: String = row["created_at"]
        guard let date = iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) else {
            throw CoreError.store("clipboard bad timestamp \(ts)")
        }
        let pinned: Int = row["is_pinned"]
        let kindRaw: String = row["content_kind"]
        guard let contentKind = ClipboardContentKind(rawValue: kindRaw) else {
            throw CoreError.store("clipboard bad content kind \(kindRaw)")
        }
        return ClipboardItem(
            id: row["id"],
            text: row["text"],
            sourceApp: row["source_app"],
            createdAt: date,
            isPinned: pinned != 0,
            contentKind: contentKind,
            flavor: row["flavor"],
            data: row["payload"]
        )
    }

    static func validate(_ item: ClipboardItem) throws {
        if let data = item.data, data.count > maximumPayloadBytes {
            throw CoreError.store("clipboard payload exceeds \(maximumPayloadBytes) bytes")
        }
        switch item.contentKind {
        case .plainText:
            guard !item.text.isEmpty else {
                throw CoreError.store("clipboard text must be non-empty")
            }
            guard item.data == nil else {
                throw CoreError.store("plain clipboard text cannot carry binary payload")
            }
        case .richText:
            guard !item.text.isEmpty, let flavor = item.flavor, let data = item.data, !data.isEmpty else {
                throw CoreError.store("rich clipboard content requires text, flavor, and payload")
            }
            guard ["public.html", "public.rtf"].contains(flavor) else {
                throw CoreError.store("unsupported rich clipboard flavor \(flavor)")
            }
        case .image:
            guard let flavor = item.flavor, let data = item.data, !data.isEmpty else {
                throw CoreError.store("image clipboard content requires flavor and payload")
            }
            guard PasteboardPrivacy.imageTypes.contains(flavor) else {
                throw CoreError.store("unsupported image clipboard flavor \(flavor)")
            }
        }
    }

    private func pruneUnpinnedIfNeeded(_ db: Database) throws {
        let overflowIDs = try String.fetchAll(
            db,
            sql: """
                SELECT id FROM clipboard_items
                WHERE is_pinned = 0
                ORDER BY rowid DESC
                LIMIT -1 OFFSET ?
                """,
            arguments: [unpinnedRetentionLimit]
        )
        guard !overflowIDs.isEmpty else { return }
        try Self.scrubRetainedPayloads(db, clipboardIDs: Set(overflowIDs))
        for id in overflowIDs {
            try db.execute(
                sql: "DELETE FROM clipboard_items WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Clipboard delete/retention is a privacy boundary: remove every journal
    /// event that embeds the deleted payload in the same database transaction.
    /// The later `clipboard.delete` event remains replayable and idempotent.
    private static func scrubRetainedPayloads(
        _ db: Database,
        clipboardIDs: Set<String>
    ) throws {
        guard !clipboardIDs.isEmpty else { return }
        let hasFrecency = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'frecency')"
        ) ?? false
        if hasFrecency {
            for id in clipboardIDs {
                let resultID = "clipboard:\(id)"
                try db.execute(
                    sql: "DELETE FROM frecency_snapshots WHERE result_id = ?",
                    arguments: [resultID]
                )
                try db.execute(
                    sql: "DELETE FROM frecency WHERE result_id = ?",
                    arguments: [resultID]
                )
            }
        }

        let rows = try Row.fetchAll(
            db,
            sql: "SELECT seq, action_json FROM action_journal"
        )
        let decoder = JSONDecoder()
        var sequences: [Int64] = []
        var historyIDs: Set<String> = []
        for row in rows {
            let sequence: Int64 = row["seq"]
            let actionJSON: String = row["action_json"]
            guard let data = actionJSON.data(using: .utf8),
                  let action = try? decoder.decode(CoreAction.self, from: data) else {
                continue
            }
            let clipboardID: String?
            var usageHistoryID: String?
            switch action {
            case .clipboardIngest(let id, _, _, _, _),
                 .clipboardIngestRich(let id, _, _, _, _, _, _, _):
                clipboardID = id
            case .moduleRun(_, let targetID, _, let payload):
                if case .string(let id) = payload["clipboardID"] {
                    clipboardID = id
                } else if targetID.hasPrefix("clipboard:") {
                    clipboardID = String(targetID.dropFirst("clipboard:".count))
                } else {
                    clipboardID = nil
                }
            case .usageRecord(
                let resultID,
                _,
                _,
                _,
                _,
                _,
                let historyID,
                _
            ):
                if resultID.hasPrefix("clipboard:") {
                    clipboardID = String(resultID.dropFirst("clipboard:".count))
                    usageHistoryID = historyID
                } else {
                    clipboardID = nil
                }
            default:
                clipboardID = nil
            }
            if let clipboardID, clipboardIDs.contains(clipboardID) {
                sequences.append(sequence)
                if let usageHistoryID {
                    historyIDs.insert(usageHistoryID)
                }
            }
        }
        for sequence in sequences {
            try db.execute(
                sql: "DELETE FROM action_journal WHERE seq = ?",
                arguments: [sequence]
            )
        }
        let hasHistory = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'search_history')"
        ) ?? false
        if hasHistory {
            for historyID in historyIDs {
                try db.execute(
                    sql: "DELETE FROM search_history WHERE id = ?",
                    arguments: [historyID]
                )
            }
        }
    }
}
