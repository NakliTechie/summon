import Foundation
import GRDB

/// Schema version stamped in `schema_meta` and every JSON export.
public enum StoreSchema {
    /// v1 spine · v2 snippets · v3 clipboard + quicklinks · v4 rich clipboard.
    public static let version = 4
}

/// Opens / migrates the Summon SQLite database under a container directory.
public enum SummonDatabase {
    public static let fileName = "summon.sqlite"
    public static let containerPermissions = 0o700
    public static let databasePermissions = 0o600
    public static let busyTimeoutSeconds: TimeInterval = 2

    /// Default container: `~/Library/Application Support/Summon/`.
    ///
    /// `SUMMON_CONTAINER_DIR` overrides the location. The Application Support
    /// API ignores `$HOME`, so tooling (`make verify`, cli-e2e) that only sets
    /// `HOME` would otherwise mutate the user's real store; the override is the
    /// hermetic seam.
    public static func defaultContainerURL() throws -> URL {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["SUMMON_CONTAINER_DIR"],
            !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try ensurePrivateContainer(dir, fileManager: fm)
            return dir
        }
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CoreError.io("Application Support directory unavailable")
        }
        let dir = base.appendingPathComponent("Summon", isDirectory: true)
        try ensurePrivateContainer(dir, fileManager: fm)
        return dir
    }

    public static func open(in container: URL) throws -> DatabaseQueue {
        let fm = FileManager.default
        try ensurePrivateContainer(container, fileManager: fm)
        let dbURL = container.appendingPathComponent(fileName)
        var config = configuration()
        config.journalMode = .wal
        let dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try fm.setAttributes(
            [.posixPermissions: databasePermissions],
            ofItemAtPath: dbURL.path
        )
        try migrator.migrate(dbQueue)
        try fm.setAttributes(
            [.posixPermissions: databasePermissions],
            ofItemAtPath: dbURL.path
        )
        return dbQueue
    }

    /// In-memory database for tests.
    public static func openInMemory() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue(configuration: configuration())
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    private static func configuration() -> Configuration {
        var config = Configuration()
        config.busyMode = .timeout(busyTimeoutSeconds)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return config
    }

    private static func ensurePrivateContainer(
        _ container: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: container,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: containerPermissions]
        )
        try fileManager.setAttributes(
            [.posixPermissions: containerPermissions],
            ofItemAtPath: container.path
        )
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
                arguments: ["schemaVersion", "1"]
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
                arguments: ["3", "schemaVersion"]
            )
        }
        migrator.registerMigration("v4_rich_clipboard") { db in
            try db.execute(sql: "ALTER TABLE clipboard_items ADD COLUMN content_kind TEXT NOT NULL DEFAULT 'plainText'")
            try db.execute(sql: "ALTER TABLE clipboard_items ADD COLUMN flavor TEXT")
            try db.execute(sql: "ALTER TABLE clipboard_items ADD COLUMN payload BLOB")
            try db.execute(sql: "ALTER TABLE clipboard_items ADD COLUMN content_hash TEXT")
            let rows = try Row.fetchAll(db, sql: "SELECT id, text FROM clipboard_items")
            for row in rows {
                let id: String = row["id"]
                let text: String = row["text"]
                let hash = ClipboardItem(id: id, text: text).contentHash
                try db.execute(
                    sql: "UPDATE clipboard_items SET content_hash = ? WHERE id = ?",
                    arguments: [hash, id]
                )
            }
            try db.execute(sql: "CREATE INDEX clipboard_content_hash_idx ON clipboard_items(content_hash)")
            try db.execute(
                sql: "UPDATE schema_meta SET value = ? WHERE key = ?",
                arguments: ["4", "schemaVersion"]
            )
        }
        return migrator
    }
}
