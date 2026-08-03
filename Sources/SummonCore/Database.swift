import Foundation
import GRDB

/// Schema version stamped in `schema_meta` and every JSON export.
public enum StoreSchema {
    /// v1 spine · v2 snippets · v3 clipboard + quicklinks.
    public static let version = 3
}

/// Opens / migrates the Summon SQLite database under a container directory.
public enum SummonDatabase {
    public static let fileName = "summon.sqlite"

    /// Default container: `~/Library/Application Support/Summon/`.
    public static func defaultContainerURL() throws -> URL {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CoreError.io("Application Support directory unavailable")
        }
        let dir = base.appendingPathComponent("Summon", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func open(in container: URL) throws -> DatabaseQueue {
        let fm = FileManager.default
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        let dbURL = container.appendingPathComponent(fileName)
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    /// In-memory database for tests.
    public static func openInMemory() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_spine") { db in
            try db.execute(sql: """
                CREATE TABLE schema_meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                """)
            try db.execute(
                sql: "INSERT INTO schema_meta (key, value) VALUES (?, ?)",
                arguments: ["schemaVersion", "\(StoreSchema.version)"]
            )

            try db.execute(sql: """
                CREATE TABLE settings (
                    key TEXT PRIMARY KEY NOT NULL,
                    value_json TEXT NOT NULL
                );
                """)

            try db.execute(sql: """
                CREATE TABLE action_journal (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    actor TEXT NOT NULL,
                    timestamp TEXT NOT NULL,
                    action_json TEXT NOT NULL,
                    outcome TEXT NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE INDEX action_journal_actor_idx ON action_journal(actor);
                """)
        }
        migrator.registerMigration("v2_snippets") { db in
            try db.execute(sql: """
                CREATE TABLE snippets (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    body TEXT NOT NULL,
                    keyword TEXT
                );
                """)
            try db.execute(sql: """
                CREATE INDEX snippets_name_idx ON snippets(name);
                """)
            try db.execute(
                sql: "UPDATE schema_meta SET value = ? WHERE key = ?",
                arguments: ["2", "schemaVersion"]
            )
        }
        migrator.registerMigration("v3_clipboard_quicklinks") { db in
            try db.execute(sql: """
                CREATE TABLE clipboard_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    text TEXT NOT NULL,
                    source_app TEXT,
                    created_at TEXT NOT NULL,
                    is_pinned INTEGER NOT NULL DEFAULT 0
                );
                """)
            try db.execute(sql: """
                CREATE INDEX clipboard_created_idx ON clipboard_items(created_at DESC);
                """)
            try db.execute(sql: """
                CREATE TABLE quicklinks (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    url TEXT NOT NULL,
                    keyword TEXT
                );
                """)
            try db.execute(
                sql: "UPDATE schema_meta SET value = ? WHERE key = ?",
                arguments: ["\(StoreSchema.version)", "schemaVersion"]
            )
        }
        return migrator
    }
}
