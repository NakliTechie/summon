import Foundation
import GRDB

/// Local settings store (SQLite). Exportable; no secrets (secrets → Keychain).
public struct SettingsStore: Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func get(_ key: String) throws -> JSONValue? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT value_json FROM settings WHERE key = ?",
                arguments: [key]
            ) else {
                return nil
            }
            let raw: String = row["value_json"]
            guard let data = raw.data(using: .utf8) else {
                throw CoreError.store("settings value not UTF-8 for key \(key)")
            }
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }
    }

    public func set(_ key: String, value: JSONValue) throws {
        let data = try JSONEncoder().encode(value)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw CoreError.store("failed to encode settings value for key \(key)")
        }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO settings (key, value_json) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json
                    """,
                arguments: [key, raw]
            )
        }
    }

    public func delete(_ key: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
        }
    }

    /// All settings as a sorted dictionary (deterministic for byte-equal export).
    public func all() throws -> [String: JSONValue] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key, value_json FROM settings ORDER BY key ASC")
            var result: [String: JSONValue] = [:]
            let decoder = JSONDecoder()
            for row in rows {
                let key: String = row["key"]
                let raw: String = row["value_json"]
                guard let data = raw.data(using: .utf8) else {
                    throw CoreError.store("settings value not UTF-8 for key \(key)")
                }
                result[key] = try decoder.decode(JSONValue.self, from: data)
            }
            return result
        }
    }
}
