import Foundation
import GRDB

/// Headless core: bus + stores + journal + SchemaGate + search. Zero AppKit.
public final class SummonCore: @unchecked Sendable {
    public let containerURL: URL?
    public let dbQueue: DatabaseQueue
    public let settings: SettingsStore
    public let snippets: SnippetStore
    public let clipboard: ClipboardStore
    public let quicklinks: QuicklinkStore
    public let journal: ActionJournal
    public let bus: ActionBus
    public let schemaGate: SchemaGate
    public let staged: StagedProposalStore
    public let frecency: FrecencyStore
    public let aliases: AliasStore
    public let history: SearchHistoryStore
    public let favorites: FavoriteStore
    public let clipboardIgnore: ClipboardIgnoreStore
    public let fts: FTSIndex
    public var search: SearchService
    public var webConfig: WebSearchConfig = .default

    public convenience init(containerURL: URL) throws {
        let dbQueue = try SummonDatabase.open(in: containerURL)
        self.init(dbQueue: dbQueue, containerURL: containerURL)
    }

    public convenience init() throws {
        let url = try SummonDatabase.defaultContainerURL()
        try self.init(containerURL: url)
    }

    public static func inMemory(
        spotlight: (any SpotlightIndexing)? = nil,
        appSearchPaths: [URL]? = nil,
        executor: (any ModuleExecuting)? = nil
    ) throws -> SummonCore {
        let dbQueue = try SummonDatabase.openInMemory()
        return SummonCore(
            dbQueue: dbQueue,
            containerURL: nil,
            spotlight: spotlight,
            appSearchPaths: appSearchPaths,
            executor: executor
        )
    }

    public init(
        dbQueue: DatabaseQueue,
        containerURL: URL?,
        spotlight: (any SpotlightIndexing)? = nil,
        appSearchPaths: [URL]? = nil,
        executor: (any ModuleExecuting)? = nil
    ) {
        self.dbQueue = dbQueue
        self.containerURL = containerURL
        self.settings = SettingsStore(dbQueue: dbQueue)
        self.snippets = SnippetStore(dbQueue: dbQueue)
        self.clipboard = ClipboardStore(dbQueue: dbQueue)
        self.quicklinks = QuicklinkStore(dbQueue: dbQueue)
        self.journal = ActionJournal(dbQueue: dbQueue)
        self.bus = ActionBus(
            settings: settings,
            snippets: snippets,
            clipboard: clipboard,
            quicklinks: quicklinks,
            journal: journal,
            executor: executor ?? RecordingModuleExecutor()
        )
        self.schemaGate = SchemaGate()
        self.staged = StagedProposalStore(dbQueue: dbQueue)
        try? self.staged.migrate()
        self.frecency = FrecencyStore(dbQueue: dbQueue)
        try? self.frecency.migrate()
        self.aliases = AliasStore(dbQueue: dbQueue)
        try? self.aliases.migrate()
        self.history = SearchHistoryStore(dbQueue: dbQueue)
        try? self.history.migrate()
        self.favorites = FavoriteStore(dbQueue: dbQueue)
        try? self.favorites.migrate()
        self.clipboardIgnore = ClipboardIgnoreStore(dbQueue: dbQueue)
        try? self.clipboardIgnore.migrate()
        self.fts = FTSIndex(dbQueue: dbQueue)
        try? self.fts.migrate()
        let ftsOn: Bool
        if case .bool(let b) = try? settings.get("search.fts.enabled") {
            ftsOn = b
        } else {
            ftsOn = false
        }
        self.search = SearchService(
            apps: AppCatalog(searchPaths: appSearchPaths),
            spotlight: spotlight ?? FakeSpotlightIndex(),
            snippets: snippets,
            clipboard: clipboard,
            quicklinks: quicklinks,
            frecency: frecency,
            fts: fts,
            ftsEnabled: ftsOn,
            favorites: favorites
        )
        // Load web config from settings if present
        if case .bool(let en) = try? settings.get("web.search.enabled") {
            webConfig.enabled = en
        }
        if case .string(let url) = try? settings.get("web.search.baseURL") {
            webConfig.baseURL = url
        }

        // Wire propose-only staging for agent/ext elevated actions
        let stagedStore = self.staged
        self.bus.stageElevated = { envelope in
            let data = try JSONEncoder().encode(envelope.action)
            guard let json = String(data: data, encoding: .utf8) else {
                throw CoreError.store("failed to encode staged action")
            }
            let proposalID = UUID().uuidString
            let proposal = PersistedStagedProposal(
                id: proposalID,
                rung: "agent",
                prompt: "\(envelope.actor.journalLabel) proposed \(envelope.action.name)",
                output: json,
                egressSummary: "local-stage",
                state: "staged"
            )
            try stagedStore.upsert(proposal)
            return proposalID
        }
    }

    /// Human accept of an agent/ext staged CoreAction (rung `agent`). Re-dispatches as `.user`.
    @discardableResult
    public func acceptStagedAgentAction(id: String) throws -> ActionResult {
        guard let proposal = try staged.get(id), proposal.state == "staged" else {
            throw CoreError.store("no staged proposal \(id)")
        }
        guard proposal.rung == "agent" else {
            throw CoreError.store("proposal \(id) is not an agent action (rung=\(proposal.rung))")
        }
        guard let data = proposal.output.data(using: .utf8) else {
            throw CoreError.store("staged action payload not UTF-8")
        }
        let action = try JSONDecoder().decode(CoreAction.self, from: data)
        try staged.setState(id: id, state: "accepted")
        return try dispatch(action: action, actor: .user)
    }

    /// Human reject of a staged agent action.
    public func rejectStagedAgentAction(id: String) throws {
        guard let proposal = try staged.get(id), proposal.state == "staged" else {
            throw CoreError.store("no staged proposal \(id)")
        }
        try staged.setState(id: id, state: "rejected")
    }

    public func setFTSEnabled(_ enabled: Bool) throws {
        try settings.set("search.fts.enabled", value: .bool(enabled))
        search.ftsEnabled = enabled
    }

    public func enableLiveSpotlight() {
        search.spotlight = MdfindSpotlightIndex()
    }

    public func setExecutor(_ executor: any ModuleExecuting) {
        bus.setExecutor(executor)
    }

    // MARK: - Dispatch

    @discardableResult
    public func dispatch(_ envelope: ActionEnvelope) throws -> ActionResult {
        try bus.dispatch(envelope)
    }

    @discardableResult
    public func dispatchExternal(
        _ data: Data,
        actor: ActorTag,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) throws -> ActionResult {
        let envelope = try schemaGate.envelope(from: data, actor: actor, id: id, timestamp: timestamp)
        return try bus.dispatch(envelope)
    }

    @discardableResult
    public func dispatch(
        action: CoreAction,
        actor: ActorTag,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) throws -> ActionResult {
        let envelope = ActionEnvelope(id: id, actor: actor, timestamp: timestamp, action: action)
        return try bus.dispatch(envelope)
    }

    /// Object→action / default invoke path — journals module.run and executes.
    @discardableResult
    public func invoke(
        actionName: String,
        result: SearchResult,
        actor: ActorTag
    ) throws -> ActionResult {
        // Store mutations that are also object actions.
        switch actionName {
        case "clipboard.delete":
            if case .string(let cid) = result.payload["clipboardID"] {
                return try dispatch(action: .clipboardDelete(id: cid), actor: actor)
            }
        case "clipboard.pin":
            if case .string(let cid) = result.payload["clipboardID"] {
                return try dispatch(action: .clipboardPin(id: cid, pinned: true), actor: actor)
            }
        case "snippet.delete":
            if case .string(let sid) = result.payload["snippetID"] {
                return try dispatch(action: .snippetDelete(id: sid), actor: actor)
            }
        case "quicklink.delete":
            if case .string(let qid) = result.payload["quicklinkID"] {
                return try dispatch(action: .quicklinkDelete(id: qid), actor: actor)
            }
        default:
            break
        }

        var payload = result.payload
        payload["title"] = .string(result.title)
        return try dispatch(
            action: .moduleRun(
                name: actionName,
                targetID: result.id,
                path: result.path,
                payload: payload
            ),
            actor: actor
        )
    }

    /// Ingest clipboard text only if privacy gate allows (Maccy parity).
    @discardableResult
    public func ingestClipboard(
        text: String,
        types: [String],
        sourceApp: String? = nil,
        actor: ActorTag = .system
    ) throws -> ActionResult? {
        guard PasteboardPrivacy.isStorableText(types: types, hasString: !text.isEmpty) else {
            return nil
        }
        if try clipboardIgnore.isIgnored(sourceApp) {
            return nil
        }
        return try dispatch(
            action: .clipboardIngest(
                id: UUID().uuidString,
                text: text,
                sourceApp: sourceApp,
                createdAt: Date(),
                pinned: false
            ),
            actor: actor
        )
    }

    /// Record usage after a successful confirm (frecency + history).
    public func recordUsage(result: SearchResult, query: String) throws {
        try frecency.record(resultID: result.id, title: result.title, kind: result.kind.rawValue)
        if !query.isEmpty {
            try history.record(query)
        }
    }

    // MARK: - Snapshot / export

    public func snapshot() throws -> CoreSnapshot {
        CoreSnapshot(
            settings: try settings.all(),
            snippets: try snippets.all(),
            clipboard: try clipboard.all(),
            quicklinks: try quicklinks.all()
        )
    }

    public func exportJSON() throws -> Data {
        try snapshot().canonicalJSON()
    }

    // MARK: - Replay

    public func replay(entries: [JournalEntry]) throws {
        for entry in entries where entry.outcome == "applied" {
            // Side-effecting module runs are not re-executed on replay (store rebuild only).
            if case .moduleRun = entry.action { continue }
            _ = try bus.dispatch(entry.envelope)
        }
    }

    public func replayedCopy() throws -> SummonCore {
        let fresh = try SummonCore.inMemory()
        try fresh.replay(entries: try journal.appliedEntries())
        return fresh
    }
}

public enum SummonVersion {
    public static let string = "0.6.0-autopilot-AG"
}

extension SummonCore {
    public func persistWebConfig() throws {
        _ = try dispatch(
            action: .settingsSet(key: "web.search.enabled", value: .bool(webConfig.enabled)),
            actor: .user
        )
        _ = try dispatch(
            action: .settingsSet(key: "web.search.baseURL", value: .string(webConfig.baseURL)),
            actor: .user
        )
    }
}
