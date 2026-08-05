import Foundation
import GRDB

/// Single action bus (invariant 7). All doors dispatch here; no parallel write paths.
public final class ActionBus: @unchecked Sendable {
    private let settings: SettingsStore
    private let snippets: SnippetStore
    private let clipboard: ClipboardStore
    private let clipboardIgnore: ClipboardIgnoreStore
    private let quicklinks: QuicklinkStore
    private let aliases: AliasStore
    private let favorites: FavoriteStore
    private let staged: StagedProposalStore
    private let frecency: FrecencyStore
    private let history: SearchHistoryStore
    private let journal: ActionJournal
    private let dbQueue: DatabaseQueue
    private var executor: any ModuleExecuting
    /// Persist agent/ext elevated ops for human accept. Returns proposal id.
    public var stageElevated: ((ActionEnvelope, Database) throws -> String)?
    /// Runs after the staged proposal and journal row commit together.
    public var didStageElevated: ((String) -> Void)?
    /// Consent remains external to SQLite, so the bus checks it before enabling FTS.
    public var ftsConsentGranted: @Sendable () -> Bool = { false }
    /// Consent is an external effect, so the bus records intent before this writer runs.
    public var grantFTSConsent: @Sendable () throws -> Void = {
        throw CoreError.store("FTS consent writer is unavailable")
    }
    private let lock = NSLock()

    public init(
        settings: SettingsStore,
        snippets: SnippetStore,
        clipboard: ClipboardStore,
        clipboardIgnore: ClipboardIgnoreStore,
        quicklinks: QuicklinkStore,
        aliases: AliasStore,
        favorites: FavoriteStore,
        staged: StagedProposalStore,
        frecency: FrecencyStore,
        history: SearchHistoryStore,
        journal: ActionJournal,
        dbQueue: DatabaseQueue,
        executor: any ModuleExecuting = RecordingModuleExecutor()
    ) {
        self.settings = settings
        self.snippets = snippets
        self.clipboard = clipboard
        self.clipboardIgnore = clipboardIgnore
        self.quicklinks = quicklinks
        self.aliases = aliases
        self.favorites = favorites
        self.staged = staged
        self.frecency = frecency
        self.history = history
        self.journal = journal
        self.dbQueue = dbQueue
        self.executor = executor
    }

    public func setExecutor(_ executor: any ModuleExecuting) {
        lock.lock(); defer { lock.unlock() }
        self.executor = executor
    }

    @discardableResult
    public func dispatch(_ envelope: ActionEnvelope) throws -> ActionResult {
        if Self.isEffect(envelope.action),
           !DestructiveGuard.requiresUserApproval(actor: envelope.actor, action: envelope.action) {
            if Self.requiresPrivacySerialization(envelope.action) {
                lock.lock()
                defer { lock.unlock() }
                return try dispatchEffect(envelope, executor: executor)
            }
            return try dispatchEffect(envelope)
        }

        lock.lock()
        defer { lock.unlock() }

        let result = try dbQueue.write { db -> ActionResult in
            if let existingLabel = try journal.outcomeLabel(envelopeID: envelope.id, in: db) {
                let existing = ActionJournal.outcome(from: existingLabel)
                    ?? .rejected(reason: "action has an unfinished effect intent")
                return ActionResult(envelopeID: envelope.id, outcome: existing)
            }

            // Agent/ext elevated ops are propose-only — stage for human accept.
            let requiresApproval = try DestructiveGuard.requiresUserApproval(
                actor: envelope.actor,
                action: envelope.action
            ) || requiresContextualApproval(envelope, in: db)
            if requiresApproval {
                let outcome: ActionResult.Outcome
                if let stageElevated {
                    do {
                        let proposalID = try stageElevated(envelope, db)
                        outcome = .staged(proposalID: proposalID)
                    } catch {
                        let reason = Self.rejectionReason(for: error)
                        outcome = .rejected(reason: "stage failed: \(reason)")
                    }
                } else {
                    outcome = .rejected(
                        reason: "propose-only: \(envelope.action.name) requires user accept (no staging store)"
                    )
                }
                let stagedResult = ActionResult(envelopeID: envelope.id, outcome: outcome)
                try journal.append(envelope: envelope, outcome: outcome, in: db)
                return stagedResult
            }

            let outcome: ActionResult.Outcome
            do {
                try apply(envelope.action, in: db, enforceFTSConsent: true)
                outcome = .applied
            } catch {
                outcome = .rejected(reason: Self.rejectionReason(for: error))
            }
            try journal.append(envelope: envelope, outcome: outcome, in: db)
            return ActionResult(envelopeID: envelope.id, outcome: outcome)
        }
        if let proposalID = result.stagedProposalID {
            didStageElevated?(proposalID)
        }
        return result
    }

    private func dispatchEffect(_ envelope: ActionEnvelope) throws -> ActionResult {
        lock.lock()
        let executor = self.executor
        lock.unlock()

        return try dispatchEffect(envelope, executor: executor)
    }

    private func dispatchEffect(
        _ envelope: ActionEnvelope,
        executor: any ModuleExecuting
    ) throws -> ActionResult {
        if let existing = try dbQueue.write({ db -> ActionResult? in
            if let existingLabel = try journal.reserveEffect(envelope, in: db) {
                let existingOutcome = ActionJournal.outcome(from: existingLabel)
                    ?? .rejected(reason: "effect intent is pending and will not be repeated")
                return ActionResult(envelopeID: envelope.id, outcome: existingOutcome)
            }
            return nil
        }) {
            return existing
        }

        let outcome: ActionResult.Outcome
        do {
            try performEffect(envelope.action, executor: executor)
            outcome = .applied
        } catch {
            outcome = .rejected(reason: Self.rejectionReason(for: error))
        }
        let result = ActionResult(envelopeID: envelope.id, outcome: outcome)
        try dbQueue.write { db in
            try journal.updateOutcome(envelopeID: envelope.id, outcome: outcome, in: db)
        }
        return result
    }

    public func applyForReplay(_ action: CoreAction) throws {
        lock.lock()
        defer { lock.unlock() }
        try dbQueue.write { db in
            try apply(action, in: db, enforceFTSConsent: false)
        }
    }

    /// Applies a prevalidated import as one transaction. Any failed action rolls back every mutation and row.
    func dispatchBatch(_ envelopes: [ActionEnvelope]) throws -> [ActionResult] {
        lock.lock()
        defer { lock.unlock() }
        return try dbQueue.write { db in
            var results: [ActionResult] = []
            results.reserveCapacity(envelopes.count)
            for envelope in envelopes {
                guard !Self.isEffect(envelope.action) else {
                    throw CoreError.store("batch imports cannot contain external effects")
                }
                guard !DestructiveGuard.requiresUserApproval(
                    actor: envelope.actor,
                    action: envelope.action
                ) else {
                    throw CoreError.store("batch action requires user approval")
                }
                if let existingLabel = try journal.outcomeLabel(envelopeID: envelope.id, in: db) {
                    let existing = ActionJournal.outcome(from: existingLabel)
                        ?? .rejected(reason: "action has an unfinished effect intent")
                    results.append(ActionResult(envelopeID: envelope.id, outcome: existing))
                    continue
                }
                try apply(envelope.action, in: db, enforceFTSConsent: true)
                try journal.append(envelope: envelope, outcome: .applied, in: db)
                results.append(ActionResult(envelopeID: envelope.id, outcome: .applied))
            }
            return results
        }
    }

    /// Commits the proposal state and its decision journal row together.
    func finalizeProposal(
        id: String,
        from expectedState: String,
        to newState: String,
        failureReason: String?,
        reviewedOutput: String? = nil,
        decision: ActionEnvelope
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try dbQueue.write { db in
            guard try staged.transition(
                id: id,
                from: expectedState,
                to: newState,
                failureReason: failureReason,
                reviewedOutput: reviewedOutput,
                in: db
            ) else {
                throw CoreError.store("proposal \(id) lost its \(expectedState) state")
            }
            try journal.append(envelope: decision, outcome: .applied, in: db)
        }
    }

    private func apply(
        _ action: CoreAction,
        in db: Database,
        enforceFTSConsent: Bool
    ) throws {
        try applyPrimary(action, in: db, enforceFTSConsent: enforceFTSConsent)
    }

    private func applyPrimary(
        _ action: CoreAction,
        in db: Database,
        enforceFTSConsent: Bool
    ) throws {
        switch action {
        case .settingsSet(let key, let value):
            try applySetting(key: key, value: value, in: db)
        case .settingsDelete(let key):
            try deleteSetting(key: key, in: db)
        case .snippetUpsert(let id, let name, let body, let keyword):
            try snippets.upsert(
                Snippet(id: id, name: name, body: body, keyword: keyword),
                in: db
            )
        case .snippetDelete(let id):
            guard !id.isEmpty else { throw CoreError.store("snippet id must be non-empty") }
            try snippets.delete(id: id, in: db)
        case .clipboardIngest(let id, let text, let sourceApp, let createdAt, let pinned):
            try clipboard.ingest(
                ClipboardItem(id: id, text: text, sourceApp: sourceApp, createdAt: createdAt, isPinned: pinned),
                in: db
            )
        case .clipboardIngestRich(
            let id,
            let text,
            let sourceApp,
            let createdAt,
            let pinned,
            let contentKind,
            let flavor,
            let data
        ):
            try clipboard.ingest(
                ClipboardItem(
                    id: id,
                    text: text,
                    sourceApp: sourceApp,
                    createdAt: createdAt,
                    isPinned: pinned,
                    contentKind: contentKind,
                    flavor: flavor,
                    data: data
                ),
                in: db
            )
        case .clipboardDelete(let id):
            try clipboard.delete(id: id, in: db)
        case .clipboardPin(let id, let pinned):
            try clipboard.setPinned(id: id, pinned: pinned, in: db)
        case .clipboardTouch(let id, let createdAt):
            try clipboard.touch(id: id, createdAt: createdAt, in: db)
        case .clipboardClearUnpinned:
            try clipboard.clearUnpinned(in: db)
        case .clipboardIgnoreAdd(let entry):
            try clipboardIgnore.add(entry, in: db)
        case .clipboardIgnoreRemove(let entry):
            try clipboardIgnore.remove(entry, in: db)
        case .quicklinkUpsert(let id, let name, let url, let keyword):
            try quicklinks.upsert(
                Quicklink(id: id, name: name, url: url, keyword: keyword),
                in: db
            )
        case .quicklinkDelete(let id):
            try quicklinks.delete(id: id, in: db)
        case .aliasSet(let keyword, let targetResultID, let title, let kind, let path, let payload):
            try aliases.set(
                LearnedAlias(
                    keyword: keyword,
                    targetResultID: targetResultID,
                    title: title,
                    kind: kind,
                    path: path,
                    payload: payload
                ),
                in: db
            )
        case .aliasDelete(let keyword):
            try aliases.delete(keyword: keyword, in: db)
        case .favoriteAdd(let id, let resultID, let title, let kind, let path):
            try favorites.add(
                FavoriteItem(id: id, resultID: resultID, title: title, kind: kind, path: path),
                in: db
            )
        case .favoriteRemove(let resultID):
            try favorites.remove(resultID: resultID, in: db)
        default:
            try applyAuxiliary(action, in: db, enforceFTSConsent: enforceFTSConsent)
        }
    }

    private func applyAuxiliary(
        _ action: CoreAction,
        in db: Database,
        enforceFTSConsent: Bool
    ) throws {
        switch action {
        case .importReset(let includeClipboard):
            try applyImportReset(includeClipboard: includeClipboard, in: db)
        case .webConfigSet(let enabled, let baseURL):
            try settings.set("web.search.enabled", value: .bool(enabled), in: db)
            try settings.set("web.search.baseURL", value: .string(baseURL), in: db)
        case .ftsConsentGrant:
            throw CoreError.store("FTS consent cannot run inside a store transaction")
        case .ftsSetEnabled(let enabled):
            try applyFTS(enabled: enabled, in: db, enforceConsent: enforceFTSConsent)
        case .usageRecord(
            let resultID,
            let title,
            let kind,
            let path,
            let payload,
            let query,
            let historyID,
            let usedAt
        ):
            guard !resultID.isEmpty, !title.isEmpty, SearchResult.Kind(rawValue: kind) != nil else {
                throw CoreError.store("usage record requires a result id, title, and known kind")
            }
            try frecency.record(
                resultID: resultID,
                title: title,
                kind: kind,
                path: path,
                payload: payload,
                at: usedAt,
                in: db
            )
            try history.record(query, id: historyID, at: usedAt, in: db)
        case .frecencyRestore(let entry):
            try frecency.restore(entry, in: db)
        case .historyRestore(let entry):
            try history.restore(entry, in: db)
        case .stagedRestore(let proposal):
            try staged.upsert(proposal, in: db)
        case .modelConsentGrant(let modelID):
            guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CoreError.store("model consent requires a model id")
            }
        case .proposalDecision, .agentSearch, .agentVersion, .agentCLI:
            break
        case .egressRequested(let purpose, let host):
            guard EgressPurpose(rawValue: purpose) != nil, !host.isEmpty else {
                throw CoreError.store("egress intent requires a known purpose and host")
            }
        case .extensionInstall, .extensionGrant, .moduleRun:
            throw CoreError.store("external effects cannot run inside a store transaction")
        default:
            throw CoreError.store("primary store action reached the auxiliary action handler")
        }
    }

    private func applyImportReset(includeClipboard: Bool, in db: Database) throws {
        try db.execute(sql: "DELETE FROM settings")
        try db.execute(sql: "DELETE FROM snippets")
        try db.execute(sql: "DELETE FROM quicklinks")
        try db.execute(sql: "DELETE FROM learned_alias_snapshots")
        try db.execute(sql: "DELETE FROM learned_aliases")
        try db.execute(sql: "DELETE FROM favorites")
        try db.execute(sql: "DELETE FROM clipboard_ignore")
        try db.execute(sql: "DELETE FROM frecency_snapshots")
        try db.execute(sql: "DELETE FROM frecency")
        try db.execute(sql: "DELETE FROM search_history")
        try db.execute(sql: "DELETE FROM staged_proposals")
        let hasFTSTable = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'fts_docs')"
        ) ?? false
        if hasFTSTable {
            try db.execute(sql: "DELETE FROM fts_docs")
        }
        if includeClipboard {
            try clipboard.clearAll(in: db)
        }
    }

    private func applySetting(key: String, value: JSONValue, in db: Database) throws {
        guard !key.isEmpty else { throw CoreError.store("settings key must be non-empty") }
        guard key != "search.fts.enabled" else {
            throw CoreError.store("use fts.setEnabled for FTS configuration")
        }
        try settings.set(key, value: value, in: db)
    }

    private func deleteSetting(key: String, in db: Database) throws {
        guard !key.isEmpty else { throw CoreError.store("settings key must be non-empty") }
        guard key != "search.fts.enabled" else {
            throw CoreError.store("use fts.setEnabled for FTS configuration")
        }
        try settings.delete(key, in: db)
    }

    private func applyFTS(
        enabled: Bool,
        in db: Database,
        enforceConsent: Bool
    ) throws {
        guard !enabled || !enforceConsent || ftsConsentGranted() else {
            throw CoreError.store("FTS consent required — run: summon fts consent")
        }
        try settings.set("search.fts.enabled", value: .bool(enabled), in: db)
        if !enabled {
            let hasFTSTable = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'fts_docs')"
            ) ?? false
            if hasFTSTable {
                try db.execute(sql: "DELETE FROM fts_docs")
            }
        }
    }

    private func performEffect(
        _ action: CoreAction,
        executor: any ModuleExecuting
    ) throws {
        switch action {
        case .extensionInstall(let sourcePath):
            try executor.installExtension(sourcePath: sourcePath)
        case .extensionGrant(let extensionID, let entitlement, let granted):
            try executor.setExtensionGrant(
                extensionID: extensionID,
                entitlement: entitlement,
                granted: granted
            )
        case .ftsConsentGrant:
            try grantFTSConsent()
        case .moduleRun:
            try performModule(action, executor: executor)
        default:
            throw CoreError.store("performEffect requires an external effect action")
        }
    }

    private func performModule(
        _ action: CoreAction,
        executor: any ModuleExecuting
    ) throws {
        guard case .moduleRun(let name, let targetID, let path, let payload) = action else {
            throw CoreError.store("performModule requires module.run")
        }
        if ["clipboard.copy", "clipboard.copyPlain"].contains(name),
           let id = Self.clipboardID(targetID: targetID, payload: payload) {
            guard let item = try clipboard.get(id: id) else {
                throw CoreError.store("clipboard item \(id) is unavailable")
            }
            try executor.copyClipboardItem(item, asPlainText: name == "clipboard.copyPlain")
            return
        }
        let kind = Self.kindHint(targetID: targetID)
        let result = SearchResult(
            id: targetID,
            title: payload["title"]?.stringValue ?? targetID,
            kind: kind,
            path: path,
            payload: payload
        )
        try ModuleRouter.perform(actionName: name, result: result, executor: executor)
    }

    private func requiresContextualApproval(
        _ envelope: ActionEnvelope,
        in db: Database
    ) throws -> Bool {
        guard envelope.actor.requiresProposeOnly else { return false }
        switch envelope.action {
        case .snippetUpsert(let id, _, _, _):
            return try snippets.get(id: id, in: db) != nil
        case .quicklinkUpsert(let id, _, _, _):
            return try quicklinks.get(id: id, in: db) != nil
        default:
            return false
        }
    }

    private static func clipboardID(
        targetID: String,
        payload: [String: JSONValue]
    ) -> String? {
        if case .string(let id) = payload["clipboardID"] { return id }
        if targetID.hasPrefix("clipboard:") {
            return String(targetID.dropFirst("clipboard:".count))
        }
        return nil
    }

    private static func requiresPrivacySerialization(_ action: CoreAction) -> Bool {
        guard case .moduleRun(let name, let targetID, _, let payload) = action else {
            return false
        }
        return name.hasPrefix("clipboard.")
            || targetID.hasPrefix("clipboard:")
            || payload["clipboardID"] != nil
    }

    private static func isEffect(_ action: CoreAction) -> Bool {
        switch action {
        case .moduleRun, .extensionInstall, .extensionGrant, .ftsConsentGrant:
            return true
        default:
            return false
        }
    }

    private static func kindHint(targetID: String) -> SearchResult.Kind {
        if targetID.hasPrefix("app:") { return .app }
        if targetID.hasPrefix("snippet:") { return .snippet }
        if targetID.hasPrefix("clipboard:") { return .clipboard }
        if targetID.hasPrefix("quicklink:") { return .quicklink }
        if targetID.hasPrefix("calc:") { return .calculation }
        if targetID.hasPrefix("emoji:") { return .emoji }
        if targetID.hasPrefix("file:") { return .file }
        return .command
    }

    private static func rejectionReason(for error: Error) -> String {
        let raw = (error as? CoreError)?.message ?? error.localizedDescription
        return String(raw.prefix(1_024))
    }
}
