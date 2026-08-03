import Foundation
import SummonCore

/// Local path install + durable storage + permission grant model (RC-20–23, E).
public struct ExtensionPermissionGrant: Sendable, Hashable, Codable, Equatable {
    public let extensionID: String
    public let entitlement: String
    public let granted: Bool
    public let grantedAt: Date

    public init(extensionID: String, entitlement: String, granted: Bool, grantedAt: Date = Date()) {
        self.extensionID = extensionID
        self.entitlement = entitlement
        self.granted = granted
        self.grantedAt = grantedAt
    }
}

public struct ExtensionInstallRecord: Sendable, Hashable, Codable, Equatable, Identifiable {
    public var id: String { extensionID }
    public let extensionID: String
    public let title: String
    public let path: String
    public let installedAt: Date

    public init(extensionID: String, title: String, path: String, installedAt: Date = Date()) {
        self.extensionID = extensionID
        self.title = title
        self.path = path
        self.installedAt = installedAt
    }
}

public final class ExtensionRegistry: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    private var installs: [ExtensionInstallRecord] = []
    private var grants: [ExtensionPermissionGrant] = []
    private var storage: [String: [String: String]] = [:] // extID → key → value

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    public static func defaultRoot() throws -> URL {
        try SummonDatabase.defaultContainerURL().appendingPathComponent("Extensions", isDirectory: true)
    }

    /// Install from a directory containing package.json-like manifest.
    public func install(fromDirectory dir: URL) throws -> ExtensionInstallRecord {
        let manifestURL = dir.appendingPathComponent("package.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try ManifestGate.decode(from: data)
        let dest = root.appendingPathComponent(manifest.name, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: dir, to: dest)
        let rec = ExtensionInstallRecord(
            extensionID: manifest.name,
            title: manifest.title,
            path: dest.path
        )
        lock.lock()
        installs.removeAll { $0.extensionID == rec.extensionID }
        installs.append(rec)
        lock.unlock()
        persist()
        return rec
    }

    public func list() -> [ExtensionInstallRecord] {
        lock.lock(); defer { lock.unlock() }
        return installs
    }

    public func setGrant(extensionID: String, entitlement: String, granted: Bool) {
        lock.lock()
        grants.removeAll { $0.extensionID == extensionID && $0.entitlement == entitlement }
        grants.append(ExtensionPermissionGrant(
            extensionID: extensionID,
            entitlement: entitlement,
            granted: granted
        ))
        lock.unlock()
        persist()
    }

    public func isGranted(extensionID: String, entitlement: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return grants.first { $0.extensionID == extensionID && $0.entitlement == entitlement }?.granted ?? false
    }

    public func requiredGrants(for manifest: ExtensionManifest) -> [ExtensionPermissionGrant] {
        manifest.entitlements.map {
            ExtensionPermissionGrant(
                extensionID: manifest.name,
                entitlement: $0,
                granted: isGranted(extensionID: manifest.name, entitlement: $0)
            )
        }
    }

    // Durable per-extension storage
    public func storageSet(extensionID: String, key: String, value: String) {
        lock.lock()
        var bag = storage[extensionID] ?? [:]
        bag[key] = value
        storage[extensionID] = bag
        lock.unlock()
        persist()
    }

    public func storageGet(extensionID: String, key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[extensionID]?[key]
    }

    private var stateURL: URL { root.appendingPathComponent("registry.json") }

    private struct Wire: Codable {
        var installs: [ExtensionInstallRecord]
        var grants: [ExtensionPermissionGrant]
        var storage: [String: [String: String]]
    }

    private func persist() {
        lock.lock()
        let wire = Wire(installs: installs, grants: grants, storage: storage)
        lock.unlock()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(wire) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let wire = try? dec.decode(Wire.self, from: data) else { return }
        installs = wire.installs
        grants = wire.grants
        storage = wire.storage
    }
}

/// Raycast backup import sketch (RC-24) — snippets/quicklinks/hotkeys JSON subset.
public enum RaycastBackupImport {
    public struct Backup: Codable {
        public var snippets: [SnippetWire]?
        public var quicklinks: [QuicklinkWire]?
        public struct SnippetWire: Codable {
            public var name: String
            public var text: String
            public var keyword: String?
        }
        public struct QuicklinkWire: Codable {
            public var name: String
            public var link: String
            public var keyword: String?
        }
    }

    public static func importBackup(data: Data, core: SummonCore) throws -> (snippets: Int, quicklinks: Int) {
        let backup = try JSONDecoder().decode(Backup.self, from: data)
        var sc = 0
        var qc = 0
        for s in backup.snippets ?? [] {
            try core.dispatch(
                action: .snippetUpsert(
                    id: UUID().uuidString,
                    name: s.name,
                    body: s.text,
                    keyword: s.keyword
                ),
                actor: .user
            )
            sc += 1
        }
        for q in backup.quicklinks ?? [] {
            try core.dispatch(
                action: .quicklinkUpsert(
                    id: UUID().uuidString,
                    name: q.name,
                    url: q.link,
                    keyword: q.keyword
                ),
                actor: .user
            )
            qc += 1
        }
        return (sc, qc)
    }
}
