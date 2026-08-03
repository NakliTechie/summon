import Foundation

/// Single action bus (invariant 7). All doors dispatch here; no parallel write paths.
///
/// The bus applies the action to stores, then journals the outcome. Callers never
/// touch stores for mutation outside this path.
public final class ActionBus: @unchecked Sendable {
    private let settings: SettingsStore
    private let journal: ActionJournal
    private let lock = NSLock()

    public init(settings: SettingsStore, journal: ActionJournal) {
        self.settings = settings
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

    /// Apply without journaling — used only by journal replay into a fresh core.
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
        }
    }
}
