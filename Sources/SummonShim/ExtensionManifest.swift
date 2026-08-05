import Foundation
import SummonCore

/// Extension package manifest. Every external payload enters via SchemaGate (invariant 6).
public struct ExtensionManifest: Sendable, Hashable, Codable, Equatable {
    public let name: String
    public let title: String
    public let commands: [Command]
    public let entitlements: [String]

    public struct Command: Sendable, Hashable, Codable, Equatable {
        public let name: String
        public let title: String
        public let mode: String
        public let entry: String?

        public init(name: String, title: String, mode: String = "view", entry: String? = nil) {
            self.name = name
            self.title = title
            self.mode = mode
            self.entry = entry
        }
    }

    public init(name: String, title: String, commands: [Command], entitlements: [String] = []) {
        self.name = name
        self.title = title
        self.commands = commands
        self.entitlements = entitlements
    }

    public var extensionID: String { name }
}

/// SchemaGate-backed loader for extension manifests.
public enum ManifestGate {
    public static let schemaVersion = 1

    private struct Wire: Codable {
        let v: Int?
        let name: String
        let title: String
        let commands: [ExtensionManifest.Command]
        let entitlements: [String]?
    }

    public static func decode(from data: Data) throws -> ExtensionManifest {
        try SchemaGate().preflightJSONObject(
            data,
            allowedRootFields: ["v", "name", "title", "commands", "entitlements"],
            arrayObjectFields: [
                "commands": ["name", "title", "mode", "entry"],
            ]
        )
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw CoreError.schemaValidation("extension manifest: \(error.localizedDescription)")
        }
        if let v = wire.v, v != schemaVersion {
            throw CoreError.schemaValidation(
                "extension manifest version \(v); expected \(schemaVersion)"
            )
        }
        let name = try validateExtensionID(wire.name)
        guard !wire.commands.isEmpty else {
            throw CoreError.schemaValidation("extension manifest requires at least one command")
        }
        for command in wire.commands {
            try validateCommand(command)
        }
        let ents = (wire.entitlements ?? []).map { normalizeEntitlement($0) }
        // Only allow known entitlement tokens
        for e in ents where !Self.allowedEntitlements.contains(e) {
            throw CoreError.schemaValidation("unknown entitlement '\(e)'")
        }
        return ExtensionManifest(
            name: name,
            title: wire.title.isEmpty ? name : wire.title,
            commands: wire.commands,
            entitlements: ents
        )
    }

    /// `^[A-Za-z0-9._-]{1,64}$` — no path separators / traversal.
    public static func validateExtensionID(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64 else {
            throw CoreError.schemaValidation("extension name must be 1…64 characters")
        }
        guard name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw CoreError.schemaValidation(
                "extension name must match [A-Za-z0-9._-]+ (no path separators)"
            )
        }
        if name == "." || name == ".." || name.contains("..") {
            throw CoreError.schemaValidation("extension name must not contain '..'")
        }
        return name
    }

    public static let allowedEntitlements: Set<String> = ["network"]

    private static func validateCommand(_ command: ExtensionManifest.Command) throws {
        guard command.name.count <= 64,
              command.name.range(
                  of: #"^[A-Za-z0-9._-]+$"#,
                  options: .regularExpression
              ) != nil else {
            throw CoreError.schemaValidation("command name must match [A-Za-z0-9._-]{1,64}")
        }
        guard !command.title.isEmpty, command.title.count <= 256 else {
            throw CoreError.schemaValidation("command title must be 1…256 characters")
        }
        guard ["view", "no-view"].contains(command.mode) else {
            throw CoreError.schemaValidation("command mode must be view or no-view")
        }
        if let entry = command.entry {
            guard !entry.isEmpty, entry.count <= 256,
                  !entry.hasPrefix("/"), !entry.contains("..") else {
                throw CoreError.schemaValidation("command entry must be a relative contained path")
            }
        }
    }

    /// `fetch` is an alias for `network` (canonical).
    public static func normalizeEntitlement(_ raw: String) -> String {
        let e = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if e == "fetch" { return "network" }
        return e
    }
}
