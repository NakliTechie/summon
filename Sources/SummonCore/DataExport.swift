import Foundation

/// Versioned local export/import (RC-53, SU-10) — no cloud.
public struct StoreExportBundle: Codable, Sendable, Equatable {
    public let version: Int
    public let exportedAt: Date
    public let snapshot: CoreSnapshot
    public let aliases: [LearnedAlias]
    public let favorites: [FavoriteItem]

    public init(
        version: Int = 1,
        exportedAt: Date = Date(),
        snapshot: CoreSnapshot,
        aliases: [LearnedAlias],
        favorites: [FavoriteItem]
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.snapshot = snapshot
        self.aliases = aliases
        self.favorites = favorites
    }
}

public enum DataExport {
    public static func export(core: SummonCore) throws -> Data {
        let bundle = StoreExportBundle(
            snapshot: try core.snapshot(),
            aliases: try core.aliases.all(),
            favorites: try core.favorites.all()
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(bundle)
    }

    public static func importJSON(_ data: Data, into core: SummonCore) throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let bundle = try dec.decode(StoreExportBundle.self, from: data)
        for (k, v) in bundle.snapshot.settings {
            try core.settings.set(k, value: v)
        }
        for s in bundle.snapshot.snippets {
            try core.dispatch(
                action: .snippetUpsert(id: s.id, name: s.name, body: s.body, keyword: s.keyword),
                actor: .user
            )
        }
        for q in bundle.snapshot.quicklinks {
            try core.dispatch(
                action: .quicklinkUpsert(id: q.id, name: q.name, url: q.url, keyword: q.keyword),
                actor: .user
            )
        }
        for a in bundle.aliases {
            try core.aliases.set(a)
        }
        for f in bundle.favorites {
            try core.favorites.add(f)
        }
    }
}
