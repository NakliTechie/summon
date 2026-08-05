import Foundation

/// Non-restorable audit metadata exported without action payloads.
public struct JournalExportRecord: Codable, Sendable, Hashable, Equatable {
    public let seq: Int64
    public let id: UUID
    public let actor: ActorTag
    public let timestamp: Date
    public let actionName: String
    public let outcome: String

    public init(
        seq: Int64,
        id: UUID,
        actor: ActorTag,
        timestamp: Date,
        actionName: String,
        outcome: String
    ) {
        self.seq = seq
        self.id = id
        self.actor = actor
        self.timestamp = timestamp
        self.actionName = actionName
        self.outcome = outcome
    }
}

/// Versioned local export/import (RC-53, SU-10) — no cloud.
public struct StoreExportBundle: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public let version: Int
    public let exportedAt: Date
    public let snapshot: CoreSnapshot
    public let aliases: [LearnedAlias]
    public let favorites: [FavoriteItem]
    public let clipboardIgnore: [String]
    public let frecency: [FrecencyEntry]
    public let history: [SearchHistoryEntry]
    public let stagedProposals: [PersistedStagedProposal]
    /// Bounded, payload-free audit window. This domain is not restored on import.
    public let journal: [JournalExportRecord]
    public let journalTotalCount: Int
    /// Clipboard is opt-in on import (privacy); export may include it for completeness.
    public let includeClipboard: Bool

    public init(
        version: Int = StoreExportBundle.currentVersion,
        exportedAt: Date = Date(),
        snapshot: CoreSnapshot,
        aliases: [LearnedAlias],
        favorites: [FavoriteItem],
        clipboardIgnore: [String] = [],
        frecency: [FrecencyEntry] = [],
        history: [SearchHistoryEntry] = [],
        stagedProposals: [PersistedStagedProposal] = [],
        journal: [JournalExportRecord] = [],
        journalTotalCount: Int = 0,
        includeClipboard: Bool = false
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.snapshot = snapshot
        self.aliases = aliases
        self.favorites = favorites
        self.clipboardIgnore = clipboardIgnore
        self.frecency = frecency
        self.history = history
        self.stagedProposals = stagedProposals
        self.journal = journal
        self.journalTotalCount = journalTotalCount
        self.includeClipboard = includeClipboard
    }
}

public enum DataExport {
    public enum ImportMode: String, Sendable, Equatable {
        /// Upsert imported records and preserve records absent from the bundle.
        case merge
        /// Clear imported store domains before inserting the bundle.
        case replace
    }

    public enum ImportError: Error, LocalizedError {
        case unsupportedVersion(Int)
        case unsupportedSchemaVersion(Int)
        case actorNotAuthorized(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "unsupported export version \(v); expected \(StoreExportBundle.currentVersion)"
            case .unsupportedSchemaVersion(let v):
                return "unsupported store schema \(v); expected \(StoreSchema.version)"
            case .actorNotAuthorized(let actor):
                return "store import requires the user actor; received \(actor)"
            case .empty:
                return "export bundle is empty"
            }
        }
    }

    public static func export(core: SummonCore, includeClipboard: Bool = false) throws -> Data {
        let bundle = try core.storeExportBundle(includeClipboard: includeClipboard)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(bundle)
    }

    /// Reads at most the schema cap plus one byte so a growing file remains bounded.
    public static func readImportFile(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw CoreError.schemaValidation("import path must be a regular file")
        }
        if let size = values.fileSize, size > SchemaGate.maximumImportDocumentBytes {
            throw CoreError.schemaValidation("import document exceeds byte limit")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: SchemaGate.maximumImportDocumentBytes + 1) ?? Data()
        guard data.count <= SchemaGate.maximumImportDocumentBytes else {
            throw CoreError.schemaValidation("import document exceeds byte limit")
        }
        return data
    }

    /// Imports a schema-gated bundle in one action-bus transaction.
    /// Clipboard remains preserved unless both the bundle and caller opt in.
    public static func importJSON(
        _ data: Data,
        into core: SummonCore,
        actor: ActorTag = .user,
        mode: ImportMode = .merge,
        importClipboard: Bool = false
    ) throws {
        guard !data.isEmpty else { throw ImportError.empty }
        guard actor == .user else {
            throw ImportError.actorNotAuthorized(actor.journalLabel)
        }
        try core.schemaGate.preflightStoreExportBundle(data)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let bundle = try dec.decode(StoreExportBundle.self, from: data)
        guard bundle.version == StoreExportBundle.currentVersion else {
            throw ImportError.unsupportedVersion(bundle.version)
        }
        guard bundle.snapshot.schemaVersion == StoreSchema.version else {
            throw ImportError.unsupportedSchemaVersion(bundle.snapshot.schemaVersion)
        }

        let includesClipboard = importClipboard && bundle.includeClipboard
        var actions: [CoreAction] = []
        if mode == .replace {
            actions.append(.importReset(includeClipboard: includesClipboard))
        }

        for key in bundle.snapshot.settings.keys.sorted() {
            guard let value = bundle.snapshot.settings[key] else { continue }
            if key == "search.fts.enabled" {
                guard case .bool(let enabled) = value else {
                    throw CoreError.schemaValidation("search.fts.enabled must be a boolean")
                }
                actions.append(.ftsSetEnabled(enabled: enabled))
            } else {
                actions.append(.settingsSet(key: key, value: value))
            }
        }
        actions.append(contentsOf: bundle.snapshot.snippets.sorted { $0.id < $1.id }.map {
            .snippetUpsert(id: $0.id, name: $0.name, body: $0.body, keyword: $0.keyword)
        })
        actions.append(contentsOf: bundle.snapshot.quicklinks.sorted { $0.id < $1.id }.map {
            .quicklinkUpsert(id: $0.id, name: $0.name, url: $0.url, keyword: $0.keyword)
        })
        if includesClipboard {
            for item in bundle.snapshot.clipboard.sorted(by: { $0.id < $1.id }) {
                actions.append(try clipboardAction(for: item))
            }
        }
        actions.append(contentsOf: bundle.aliases.sorted { $0.keyword < $1.keyword }.map {
            .aliasSet(
                keyword: $0.keyword,
                targetResultID: $0.targetResultID,
                title: $0.title,
                kind: $0.kind,
                path: $0.path,
                payload: $0.payload
            )
        })
        actions.append(contentsOf: bundle.favorites.sorted { $0.resultID < $1.resultID }.map {
            .favoriteAdd(
                id: $0.id,
                resultID: $0.resultID,
                title: $0.title,
                kind: $0.kind,
                path: $0.path
            )
        })
        actions.append(contentsOf: bundle.clipboardIgnore.sorted().map {
            .clipboardIgnoreAdd(entry: $0)
        })
        actions.append(contentsOf: bundle.frecency.sorted { $0.resultID < $1.resultID }.map {
            .frecencyRestore(entry: $0)
        })
        actions.append(contentsOf: bundle.history.sorted { $0.createdAt < $1.createdAt }.map {
            .historyRestore(entry: $0)
        })
        actions.append(contentsOf: bundle.stagedProposals.sorted { $0.createdAt < $1.createdAt }.map {
            .stagedRestore(proposal: $0)
        })

        _ = try core.dispatchBatch(actions: actions, actor: actor)
    }

    private static func clipboardAction(for item: ClipboardItem) throws -> CoreAction {
        if item.contentKind == .plainText {
            return .clipboardIngest(
                id: item.id,
                text: item.text,
                sourceApp: item.sourceApp,
                createdAt: item.createdAt,
                pinned: item.isPinned
            )
        }
        guard let flavor = item.flavor, let data = item.data else {
            throw CoreError.store("import clipboard item \(item.id) has incomplete rich content")
        }
        return .clipboardIngestRich(
            id: item.id,
            text: item.text,
            sourceApp: item.sourceApp,
            createdAt: item.createdAt,
            pinned: item.isPinned,
            contentKind: item.contentKind,
            flavor: flavor,
            data: data
        )
    }
}
