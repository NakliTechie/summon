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
        guard !wire.name.isEmpty else {
            throw CoreError.schemaValidation("extension manifest requires name")
        }
        guard !wire.commands.isEmpty else {
            throw CoreError.schemaValidation("extension manifest requires at least one command")
        }
        for cmd in wire.commands where cmd.name.isEmpty {
            throw CoreError.schemaValidation("command name must be non-empty")
        }
        return ExtensionManifest(
            name: wire.name,
            title: wire.title.isEmpty ? wire.name : wire.title,
            commands: wire.commands,
            entitlements: wire.entitlements ?? []
        )
    }
}
