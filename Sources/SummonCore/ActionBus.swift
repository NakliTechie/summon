import Foundation

/// Single action bus (invariant 7). All doors dispatch here; no parallel write paths.
public final class ActionBus: @unchecked Sendable {
    private let settings: SettingsStore
    private let snippets: SnippetStore
    private let journal: ActionJournal
    private let lock = NSLock()

    public init(settings: SettingsStore, snippets: SnippetStore, journal: ActionJournal) {
        self.settings = settings
        self.snippets = snippets
        self.journal = journal
    }

    @discardableResult
    public func dispatch(_ envelope: ActionEnvelope) throws -> ActionResult {
        lock.lock()
        defer { lock.unlock() }

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
            guard !key.isEmpty else {
                throw CoreError.store("settings key must be non-empty")
            }
            try settings.set(key, value: value)
        case .settingsDelete(let key):
            guard !key.isEmpty else {
                throw CoreError.store("settings key must be non-empty")
            }
            try settings.delete(key)
        case .snippetUpsert(let id, let name, let body, let keyword):
            try snippets.upsert(Snippet(id: id, name: name, body: body, keyword: keyword))
        case .snippetDelete(let id):
            guard !id.isEmpty else {
                throw CoreError.store("snippet id must be non-empty")
            }
            try snippets.delete(id: id)
        }
    }
}
