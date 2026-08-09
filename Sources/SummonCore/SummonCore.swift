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
    /// In-memory cores keep consent under a private temp dir (not shared).
    private let ftsConsentContainer: URL
    /// Migration / startup issues (empty when all optional tables migrated cleanly).
    public private(set) var startupWarnings: [String] = []

    public convenience init(containerURL: URL) throws {
        let dbQueue = try SummonDatabase.open(in: containerURL)
        self.init(
            dbQueue: dbQueue,
            containerURL: containerURL,
            spotlight: MdfindSpotlightIndex(),
            executor: ProcessModuleExecutor()
        )
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
            spotlight: spotlight ?? FakeSpotlightIndex(),
            appSearchPaths: appSearchPaths,
            executor: executor ?? RecordingModuleExecutor()
        )
    }

    public init(
        dbQueue: DatabaseQueue,
        containerURL: URL?,
        spotlight: any SpotlightIndexing,
        appSearchPaths: [URL]? = nil,
        executor: any ModuleExecuting
    ) {
        self.dbQueue = dbQueue
        self.containerURL = containerURL
        if let containerURL {
            self.ftsConsentContainer = containerURL
        } else {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("summon-fts-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            self.ftsConsentContainer = tmp
        }
        self.settings = SettingsStore(dbQueue: dbQueue)
        self.snippets = SnippetStore(dbQueue: dbQueue)
        self.clipboard = ClipboardStore(dbQueue: dbQueue)
        self.quicklinks = QuicklinkStore(dbQueue: dbQueue)
        self.journal = ActionJournal(dbQueue: dbQueue)
        let ignoreStore = ClipboardIgnoreStore(dbQueue: dbQueue)
        let aliasStore = AliasStore(dbQueue: dbQueue)
        let favoriteStore = FavoriteStore(dbQueue: dbQueue)
        let stagedStore = StagedProposalStore(dbQueue: dbQueue)
        let frecencyStore = FrecencyStore(dbQueue: dbQueue)
        let historyStore = SearchHistoryStore(dbQueue: dbQueue)
        self.bus = ActionBus(
            settings: settings,
            snippets: snippets,
            clipboard: clipboard,
            clipboardIgnore: ignoreStore,
            quicklinks: quicklinks,
            aliases: aliasStore,
            favorites: favoriteStore,
            staged: stagedStore,
            frecency: frecencyStore,
            history: historyStore,
            journal: journal,
            dbQueue: dbQueue,
            executor: executor
        )
        self.schemaGate = SchemaGate()
        let ftsIndex = FTSIndex(dbQueue: dbQueue)
        self.staged = stagedStore
        self.frecency = frecencyStore
        self.aliases = aliasStore
        self.history = historyStore
        self.favorites = favoriteStore
        self.clipboardIgnore = ignoreStore
        self.fts = ftsIndex

        self.startupWarnings = Self.collectStartupWarnings(
            migrations: [
                ("staged", stagedStore.migrate),
                ("frecency", frecencyStore.migrate),
                ("aliases", aliasStore.migrate),
                ("history", historyStore.migrate),
                ("favorites", favoriteStore.migrate),
                ("clipboardIgnore", ignoreStore.migrate),
                ("fts", ftsIndex.migrate),
            ],
            staged: stagedStore,
            journal: journal
        )

        let persistedFTSEnabled: Bool
        if case .bool(let b) = try? settings.get("search.fts.enabled") {
            persistedFTSEnabled = b
        } else {
            persistedFTSEnabled = false
        }
        let consentStore = FTSConsentStore(container: ftsConsentContainer)
        let ftsHasConsent = consentStore.load().granted
        let ftsOn = persistedFTSEnabled && ftsHasConsent
        if persistedFTSEnabled && !ftsHasConsent {
            self.startupWarnings.append(
                "fts: enabled setting ignored because consent is absent"
            )
        }
        self.search = SearchService(
            apps: AppCatalog(searchPaths: appSearchPaths),
            spotlight: spotlight,
            snippets: snippets,
            clipboard: clipboard,
            quicklinks: quicklinks,
            frecency: frecencyStore,
            fts: ftsIndex,
            ftsEnabled: ftsOn,
            favorites: favoriteStore
        )
        // Web search is available by default (no enable step); a persisted choice —
        // including the user turning it off — wins. Egress still requires the
        // one-time `.userWeb` consent, so default-on is availability, not egress.
        webConfig.enabled = true
        if case .bool(let en) = try? settings.get("web.search.enabled") {
            webConfig.enabled = en
        }
        if case .string(let url) = try? settings.get("web.search.baseURL") {
            webConfig.baseURL = url
        }

        configureActionBus(stagedStore: stagedStore, consentStore: consentStore)
    }

    private func configureActionBus(
        stagedStore: StagedProposalStore,
        consentStore: FTSConsentStore
    ) {
        self.bus.stageElevated = { envelope, db in
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
            try stagedStore.upsert(proposal, in: db)
            return proposalID
        }
        self.bus.didStageElevated = { proposalID in
            NotificationCenter.default.post(
                name: .summonStagedProposalDidChange,
                object: nil,
                userInfo: ["proposalID": proposalID]
            )
        }
        self.bus.ftsConsentGranted = { [weak self] in
            self?.ftsConsentGranted() ?? false
        }
        self.bus.grantFTSConsent = {
            var consent = consentStore.load()
            consent.grant()
            try consentStore.save(consent)
        }
    }

    /// Human accept of an agent/ext staged CoreAction (rung `agent`). Re-dispatches as `.user`.
    @discardableResult
    public func acceptStagedAgentAction(
        id: String,
        reviewedOutput: String,
        actor: ActorTag
    ) throws -> ActionResult {
        guard actor == .user else {
            throw CoreError.store("staged agent actions require human acceptance in Summon UI")
        }
        guard let data = reviewedOutput.data(using: .utf8) else {
            throw CoreError.store("reviewed action payload not UTF-8")
        }
        let action = try SchemaGate().decodeReviewedAction(from: data)
        guard let actionID = UUID(uuidString: id) else {
            throw CoreError.store("proposal id cannot identify the accepted action")
        }
        guard try staged.claimForApply(
            id: id,
            rung: "agent",
            reviewedOutput: reviewedOutput
        ) != nil else {
            throw CoreError.store("proposal \(id) is not a staged agent action")
        }
        let result = try dispatch(action: action, actor: .user, id: actionID)
        let state: String
        let reason: String?
        switch result.outcome {
        case .applied:
            state = "accepted"
            reason = nil
        case .rejected(let rejection):
            state = "apply_failed"
            reason = rejection
        case .staged(let proposalID):
            state = "apply_failed"
            reason = "accepted action restaged as \(proposalID)"
        }
        try finalizeProposal(
            id: id,
            from: "applying",
            to: state,
            reason: reason,
            actor: actor
        )
        notifyStagedProposalChange(id: id)
        return result
    }

    /// Human reject of a staged agent action.
    public func rejectStagedAgentAction(id: String, actor: ActorTag) throws {
        guard actor == .user else {
            throw CoreError.store("staged agent actions require human rejection in Summon UI")
        }
        guard let proposal = try staged.get(id), proposal.rung == "agent" else {
            throw CoreError.store("proposal \(id) is not an agent action")
        }
        try rejectStagedProposal(id: id, actor: actor)
    }

    /// Human acceptance of staged generated text. The reviewed text and decision commit together.
    public func acceptStagedTextProposal(
        id: String,
        reviewedOutput: String,
        actor: ActorTag
    ) throws {
        guard actor == .user else {
            throw CoreError.store("staged text requires human acceptance")
        }
        guard let proposal = try staged.get(id), proposal.rung != "agent" else {
            throw CoreError.store("proposal \(id) is not staged generated text")
        }
        try finalizeProposal(
            id: id,
            from: "staged",
            to: "accepted",
            reason: nil,
            reviewedOutput: reviewedOutput,
            actor: actor
        )
        notifyStagedProposalChange(id: id)
    }

    /// Human rejection of any staged proposal. State and decision journal commit together.
    public func rejectStagedProposal(id: String, actor: ActorTag) throws {
        guard actor == .user else {
            throw CoreError.store("staged proposals require human rejection")
        }
        guard let proposal = try staged.get(id), proposal.state == "staged" else {
            throw CoreError.store("proposal \(id) is not staged")
        }
        try finalizeProposal(
            id: id,
            from: "staged",
            to: "rejected",
            reason: nil,
            actor: actor
        )
        notifyStagedProposalChange(id: id)
    }

    private func finalizeProposal(
        id: String,
        from expectedState: String,
        to newState: String,
        reason: String? = nil,
        reviewedOutput: String? = nil,
        actor: ActorTag
    ) throws {
        let decision = ActionEnvelope(
            actor: actor,
            action: .proposalDecision(id: id, state: newState, reason: reason)
        )
        try bus.finalizeProposal(
            id: id,
            from: expectedState,
            to: newState,
            failureReason: reason,
            reviewedOutput: reviewedOutput,
            decision: decision
        )
    }

    private static func collectStartupWarnings(
        migrations: [(String, () throws -> Void)],
        staged: StagedProposalStore,
        journal: ActionJournal
    ) -> [String] {
        var warnings: [String] = []
        for (name, migrate) in migrations {
            do { try migrate() } catch {
                warnings.append("\(name): \(error.localizedDescription)")
            }
        }
        do {
            let recovery = try staged.reconcileApplying(journal: journal)
            if recovery.total > 0 {
                warnings.append(
                    "staged recovery: reset \(recovery.resetToStaged), "
                        + "accepted \(recovery.accepted), failed \(recovery.failed)"
                )
            }
        } catch {
            warnings.append("staged recovery: \(error.localizedDescription)")
        }
        do {
            let expired = try staged.expireStale()
            if expired > 0 {
                warnings.append("staged: expired \(expired) unreviewed proposal(s)")
            }
        } catch {
            warnings.append("staged expiry: \(error.localizedDescription)")
        }
        do {
            let readResult = try journal.readAll()
            for entry in readResult.entries where entry.outcome == "intent" {
                warnings.append(
                    "journal effect intent \(entry.seq): \(entry.action.name) outcome unresolved"
                )
            }
            for corruption in readResult.corruptions {
                let location = corruption.seq.map(String.init) ?? "unknown"
                warnings.append("journal row \(location): \(corruption.reason)")
            }
            if readResult.didReachMaterializationLimit {
                warnings.append("journal scan stopped at the bounded materialization limit")
            }
        } catch {
            warnings.append("journal scan: \(error.localizedDescription)")
        }
        do {
            _ = try staged.list(state: nil)
        } catch {
            warnings.append("staged scan: \(error.localizedDescription)")
        }
        return warnings
    }

    private func notifyStagedProposalChange(id: String) {
        NotificationCenter.default.post(
            name: .summonStagedProposalDidChange,
            object: nil,
            userInfo: ["proposalID": id]
        )
    }

    // MARK: - Dispatch

    @discardableResult
    public func dispatch(_ envelope: ActionEnvelope) throws -> ActionResult {
        let result = try bus.dispatch(envelope)
        synchronizeRuntimeState(after: result, action: envelope.action)
        return result
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
        let result = try bus.dispatch(envelope)
        synchronizeRuntimeState(after: result, action: action)
        return result
    }

    @discardableResult
    func dispatchBatch(actions: [CoreAction], actor: ActorTag) throws -> [ActionResult] {
        let timestamp = Date()
        let envelopes = actions.map {
            ActionEnvelope(actor: actor, timestamp: timestamp, action: $0)
        }
        let results = try bus.dispatchBatch(envelopes)
        for (result, action) in zip(results, actions) {
            synchronizeRuntimeState(after: result, action: action)
        }
        return results
    }

    func synchronizeRuntimeState(after result: ActionResult, action: CoreAction) {
        guard result.isApplied else { return }
        switch action {
        case .webConfigSet(let enabled, let baseURL):
            webConfig.enabled = enabled
            webConfig.baseURL = baseURL
        case .ftsSetEnabled(let enabled):
            search.ftsEnabled = enabled
        case .settingsSet(let key, let value):
            if key == "web.search.enabled", case .bool(let enabled) = value {
                webConfig.enabled = enabled
            }
            if key == "web.search.baseURL", case .string(let baseURL) = value {
                webConfig.baseURL = baseURL
            }
        case .settingsDelete(let key):
            if key == "web.search.enabled" { webConfig.enabled = false }
            if key == "web.search.baseURL" { webConfig.baseURL = WebSearchConfig.default.baseURL }
        case .importReset:
            webConfig = .default
            search.ftsEnabled = false
        default:
            break
        }
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
        case "clipboard.unpin":
            if case .string(let cid) = result.payload["clipboardID"] {
                return try dispatch(action: .clipboardPin(id: cid, pinned: false), actor: actor)
            }
        case "snippet.delete":
            if case .string(let sid) = result.payload["snippetID"] {
                return try dispatch(action: .snippetDelete(id: sid), actor: actor)
            }
        case "quicklink.delete":
            if case .string(let qid) = result.payload["quicklinkID"] {
                return try dispatch(action: .quicklinkDelete(id: qid), actor: actor)
            }
        case "favorite.add":
            return try dispatch(
                action: .favoriteAdd(
                    id: UUID().uuidString,
                    resultID: result.id,
                    title: result.title,
                    kind: result.kind.rawValue,
                    path: result.path
                ),
                actor: actor
            )
        case "favorite.remove":
            return try dispatch(action: .favoriteRemove(resultID: result.id), actor: actor)
        default:
            break
        }

        var payload = result.payload
        payload["title"] = .string(result.title)
        let outcome = try dispatch(
            action: .moduleRun(
                name: actionName,
                targetID: result.id,
                path: result.path,
                payload: payload
            ),
            actor: actor
        )
        if outcome.isApplied,
           result.kind == .clipboard,
           ["clipboard.copy", "clipboard.copyPlain"].contains(actionName),
           case .string(let clipboardID) = result.payload["clipboardID"] {
            _ = try dispatch(
                action: .clipboardTouch(id: clipboardID, createdAt: Date()),
                actor: actor
            )
        }
        return outcome
    }

    /// Ingest clipboard text only if privacy gate allows (Maccy parity).
    @discardableResult
    public func ingestClipboard(
        text: String,
        types: [String],
        sourceApp: String? = nil,
        sourceBundleID: String? = nil,
        observedSourceApp: String? = nil,
        observedSourceBundleID: String? = nil,
        actor: ActorTag = .system
    ) throws -> ActionResult? {
        guard PasteboardPrivacy.isStorableText(types: types, hasString: !text.isEmpty) else {
            return nil
        }
        if try clipboardIgnore.isIgnored(
            appName: sourceApp,
            bundleIdentifier: sourceBundleID
        ) || clipboardIgnore.isIgnored(
            appName: observedSourceApp,
            bundleIdentifier: observedSourceBundleID
        ) {
            return nil
        }
        return try ingestClipboard(
            item: ClipboardItem(text: text, sourceApp: sourceApp),
            types: types,
            sourceApp: sourceApp,
            sourceBundleID: sourceBundleID,
            observedSourceApp: observedSourceApp,
            observedSourceBundleID: observedSourceBundleID,
            actor: actor
        )
    }

    /// Ingest a privacy-vetted text, rich-text, or image clipboard item.
    @discardableResult
    public func ingestClipboard(
        item: ClipboardItem,
        types: [String],
        sourceApp: String? = nil,
        sourceBundleID: String? = nil,
        observedSourceApp: String? = nil,
        observedSourceBundleID: String? = nil,
        actor: ActorTag = .system
    ) throws -> ActionResult? {
        guard !PasteboardPrivacy.shouldSkip(types: types) else { return nil }
        try ClipboardStore.validate(item)
        if try clipboardIgnore.isIgnored(
            appName: sourceApp,
            bundleIdentifier: sourceBundleID
        ) || clipboardIgnore.isIgnored(
            appName: observedSourceApp,
            bundleIdentifier: observedSourceBundleID
        ) {
            return nil
        }
        let action: CoreAction
        if item.contentKind == .plainText {
            action = .clipboardIngest(
                id: item.id,
                text: item.text,
                sourceApp: item.sourceApp,
                createdAt: item.createdAt,
                pinned: item.isPinned
            )
        } else if let flavor = item.flavor, let data = item.data {
            action = .clipboardIngestRich(
                id: item.id,
                text: item.text,
                sourceApp: item.sourceApp,
                createdAt: item.createdAt,
                pinned: item.isPinned,
                contentKind: item.contentKind,
                flavor: flavor,
                data: data
            )
        } else {
            throw CoreError.store("rich clipboard content is incomplete")
        }
        return try dispatch(action: action, actor: actor)
    }

    /// Record usage after a successful confirm (frecency + history).
    public func recordUsage(
        result: SearchResult,
        query: String,
        actor: ActorTag = .user,
        at date: Date = Date()
    ) throws {
        let outcome = try dispatch(
            action: .usageRecord(
                resultID: result.id,
                title: result.title,
                kind: result.kind.rawValue,
                path: result.path,
                payload: result.payload,
                query: query,
                historyID: UUID().uuidString,
                usedAt: date
            ),
            actor: actor,
            timestamp: date
        )
        guard outcome.isApplied else {
            throw CoreError.store("usage record was not applied: \(outcome.outcome)")
        }
    }

}

public enum SummonVersion {
    /// Single product version — packaging (cask, Info.plist, release zip) must match.
    public static let string = "0.6.2"
}

extension SummonCore {
    /// Enable S2 FTS only after explicit consent (Batch C).
    public func setFTSEnabled(_ enabled: Bool, actor: ActorTag = .user) throws {
        let result = try dispatch(action: .ftsSetEnabled(enabled: enabled), actor: actor)
        guard result.isApplied else {
            throw CoreError.store("FTS configuration was not applied: \(result.outcome)")
        }
    }

    public func ftsConsentStore() -> FTSConsentStore {
        FTSConsentStore(container: ftsConsentContainer)
    }

    public func grantFTSConsent(actor: ActorTag = .user) throws {
        let result = try dispatch(action: .ftsConsentGrant, actor: actor)
        guard result.isApplied else {
            throw CoreError.store("FTS consent was not granted: \(result.outcome)")
        }
    }

    public func ftsConsentGranted() -> Bool {
        ftsConsentStore().load().granted
    }

    public func enableLiveSpotlight() {
        search.spotlight = MdfindSpotlightIndex()
    }

    public func setExecutor(_ executor: any ModuleExecuting) {
        bus.setExecutor(executor)
    }

    @discardableResult
    public func persistWebConfig(actor: ActorTag) throws -> ActionResult {
        let priorEnabled = try settings.get("web.search.enabled")?.boolValue ?? false
        let priorBaseURL = try settings.get("web.search.baseURL")?.stringValue ?? ""
        let result = try dispatch(
            action: .webConfigSet(enabled: webConfig.enabled, baseURL: webConfig.baseURL),
            actor: actor
        )
        if !result.isApplied {
            webConfig.enabled = priorEnabled
            webConfig.baseURL = priorBaseURL
        }
        return result
    }
}
