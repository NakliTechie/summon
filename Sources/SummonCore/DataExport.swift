import Foundation

/// Versioned local export/import (RC-53, SU-10) — no cloud.
public struct StoreExportBundle: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let exportedAt: Date
    public let snapshot: CoreSnapshot
    public let aliases: [LearnedAlias]
    public let favorites: [FavoriteItem]
    /// Clipboard is opt-in on import (privacy); export may include it for completeness.
    public let includeClipboard: Bool

    public init(
        version: Int = StoreExportBundle.currentVersion,
        exportedAt: Date = Date(),
        snapshot: CoreSnapshot,
        aliases: [LearnedAlias],
        favorites: [FavoriteItem],
        includeClipboard: Bool = false
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.snapshot = snapshot
        self.aliases = aliases
        self.favorites = favorites
        self.includeClipboard = includeClipboard
    }
}

public enum DataExport {
    public enum ImportError: Error, LocalizedError {
        case unsupportedVersion(Int)
        case empty

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "unsupported export version \(v); expected \(StoreExportBundle.currentVersion)"
            case .empty:
                return "export bundle is empty"
            }
        }
    }

    public static func export(core: SummonCore, includeClipboard: Bool = false) throws -> Data {
        var snap = try core.snapshot()
        if !includeClipboard {
            snap = CoreSnapshot(
                schemaVersion: snap.schemaVersion,
                settings: snap.settings,
                snippets: snap.snippets,
                clipboard: [],
                quicklinks: snap.quicklinks
            )
        }
        let bundle = StoreExportBundle(
            snapshot: snap,
            aliases: try core.aliases.all(),
            favorites: try core.favorites.all(),
            includeClipboard: includeClipboard
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(bundle)
    }

    /// Import via action bus for settings/snippets/quicklinks (invariant 7).
    /// Clipboard omitted unless bundle.includeClipboard and importClipboard=true.
    /// Aliases/favorites use their stores (no CoreAction yet) after bus writes.
    public static func importJSON(
        _ data: Data,
        into core: SummonCore,
        importClipboard: Bool = false
    ) throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let bundle = try dec.decode(StoreExportBundle.self, from: data)
        guard bundle.version == StoreExportBundle.currentVersion else {
            throw ImportError.unsupportedVersion(bundle.version)
        }

        // Settings through the bus so they journal as user
        for (key, value) in bundle.snapshot.settings {
            let result = try core.dispatch(
                action: .settingsSet(key: key, value: value),
                actor: .user
            )
            guard result.isApplied else {
                throw CoreError.store("import settings failed for \(key)")
            }
        }
        for s in bundle.snapshot.snippets {
            let result = try core.dispatch(
                action: .snippetUpsert(id: s.id, name: s.name, body: s.body, keyword: s.keyword),
                actor: .user
            )
            guard result.isApplied else {
                throw CoreError.store("import snippet failed for \(s.id)")
            }
        }
        for q in bundle.snapshot.quicklinks {
            let result = try core.dispatch(
                action: .quicklinkUpsert(id: q.id, name: q.name, url: q.url, keyword: q.keyword),
                actor: .user
            )
            guard result.isApplied else {
                throw CoreError.store("import quicklink failed for \(q.id)")
            }
        }
        if importClipboard, bundle.includeClipboard {
            for item in bundle.snapshot.clipboard {
                let result = try core.dispatch(
                    action: .clipboardIngest(
                        id: item.id,
                        text: item.text,
                        sourceApp: item.sourceApp,
                        createdAt: item.createdAt,
                        pinned: item.isPinned
                    ),
                    actor: .user
                )
                guard result.isApplied else {
                    throw CoreError.store("import clipboard failed for \(item.id)")
                }
            }
        }
        for a in bundle.aliases {
            try core.aliases.set(a)
        }
        for f in bundle.favorites {
            try core.favorites.add(f)
        }
    }
}
