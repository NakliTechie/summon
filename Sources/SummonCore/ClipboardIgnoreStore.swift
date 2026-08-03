import Foundation
import GRDB

/// Per-app clipboard ignore list (RC-60).
public struct ClipboardIgnoreStore: Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS clipboard_ignore (
                    bundle_or_name TEXT PRIMARY KEY NOT NULL
                );
                """)
        }
    }

    public func add(_ app: String) throws {
        let key = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO clipboard_ignore (bundle_or_name) VALUES (?)",
                arguments: [key]
            )
        }
    }

    public func remove(_ app: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM clipboard_ignore WHERE bundle_or_name = ?",
                arguments: [app]
            )
        }
    }

    public func all() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT bundle_or_name FROM clipboard_ignore ORDER BY 1")
        }
    }

    public func isIgnored(_ app: String?) throws -> Bool {
        guard let app, !app.isEmpty else { return false }
        return try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM clipboard_ignore WHERE bundle_or_name = ?",
                arguments: [app]
            ) != nil
        }
    }
}
