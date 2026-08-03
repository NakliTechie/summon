import Foundation

/// Single action bus (invariant 7). All doors dispatch here; no parallel write paths.
public final class ActionBus: @unchecked Sendable {
    private let settings: SettingsStore
    private let snippets: SnippetStore
    private let clipboard: ClipboardStore
    private let quicklinks: QuicklinkStore
    private let journal: ActionJournal
    private var executor: any ModuleExecuting
    private let lock = NSLock()

    public init(
        settings: SettingsStore,
        snippets: SnippetStore,
        clipboard: ClipboardStore,
        quicklinks: QuicklinkStore,
        journal: ActionJournal,
        executor: any ModuleExecuting = RecordingModuleExecutor()
    ) {
        self.settings = settings
        self.snippets = snippets
        self.clipboard = clipboard
        self.quicklinks = quicklinks
        self.journal = journal
        self.executor = executor
    }

    public func setExecutor(_ executor: any ModuleExecuting) {
        lock.lock(); defer { lock.unlock() }
        self.executor = executor
    }

    @discardableResult
    public func dispatch(_ envelope: ActionEnvelope) throws -> ActionResult {
        lock.lock()
        defer { lock.unlock() }

        // Agents: destructive ops are propose-only (RC-42)
        if !DestructiveGuard.agentMayApply(actor: envelope.actor, action: envelope.action) {
            let outcome = ActionResult.Outcome.rejected(
                reason: "agent propose-only: destructive action \(envelope.action.name) requires user accept"
            )
            let result = ActionResult(envelopeID: envelope.id, outcome: outcome)
            try journal.append(envelope: envelope, outcome: outcome)
            return result
        }

        let outcome: ActionResult.Outcome
        do {
            try apply(envelope.action)
            outcome = .applied
        } catch let error as CoreError {
            outcome = .rejected(reason: error.message)
            let result = ActionResult(envelopeID: envelope.id, outcome: outcome)
            try journal.append(envelope: envelope, outcome: outcome)
            return result
        }

        let result = ActionResult(envelopeID: envelope.id, outcome: outcome)
        try journal.append(envelope: envelope, outcome: outcome)
        return result
    }

    public func applyForReplay(_ action: CoreAction) throws {
        lock.lock()
        defer { lock.unlock() }
        try apply(action)
    }

    private func apply(_ action: CoreAction) throws {
        switch action {
        case .settingsSet(let key, let value):
            guard !key.isEmpty else { throw CoreError.store("settings key must be non-empty") }
            try settings.set(key, value: value)
        case .settingsDelete(let key):
            guard !key.isEmpty else { throw CoreError.store("settings key must be non-empty") }
            try settings.delete(key)
        case .snippetUpsert(let id, let name, let body, let keyword):
            try snippets.upsert(Snippet(id: id, name: name, body: body, keyword: keyword))
        case .snippetDelete(let id):
            guard !id.isEmpty else { throw CoreError.store("snippet id must be non-empty") }
            try snippets.delete(id: id)
        case .clipboardIngest(let id, let text, let sourceApp, let createdAt, let pinned):
            try clipboard.ingest(
                ClipboardItem(id: id, text: text, sourceApp: sourceApp, createdAt: createdAt, isPinned: pinned)
            )
        case .clipboardDelete(let id):
            try clipboard.delete(id: id)
        case .clipboardPin(let id, let pinned):
            try clipboard.setPinned(id: id, pinned: pinned)
        case .clipboardClearUnpinned:
            try clipboard.clearUnpinned()
        case .quicklinkUpsert(let id, let name, let url, let keyword):
            try quicklinks.upsert(Quicklink(id: id, name: name, url: url, keyword: keyword))
        case .quicklinkDelete(let id):
            try quicklinks.delete(id: id)
        case .moduleRun(let name, let targetID, let path, let payload):
            // Reconstruct a minimal SearchResult for the router.
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
    }

    private static func kindHint(targetID: String) -> SearchResult.Kind {
        if targetID.hasPrefix("app:") { return .app }
        if targetID.hasPrefix("snippet:") { return .snippet }
        if targetID.hasPrefix("clipboard:") { return .clipboard }
        if targetID.hasPrefix("quicklink:") { return .quicklink }
        if targetID.hasPrefix("calc:") { return .calculation }
        if targetID.hasPrefix("file:") { return .file }
        return .command
    }
}
