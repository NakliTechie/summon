import Foundation

public struct LauncherConfirmation: Sendable, Equatable {
    public let actionName: String
    public let result: SearchResult
    public let query: String
    public let requiresUserConfirmation: Bool

    public init(
        actionName: String,
        result: SearchResult,
        query: String,
        requiresUserConfirmation: Bool
    ) {
        self.actionName = actionName
        self.result = result
        self.query = query
        self.requiresUserConfirmation = requiresUserConfirmation
    }
}

/// Headless controller for the launcher bar: query → results → selection → invoke.
/// AppKit panel and CLI both drive this; keeps UI free of business logic.
public final class LauncherSession: @unchecked Sendable {
    public let core: SummonCore
    public private(set) var query: String = ""
    public private(set) var results: [SearchResult] = []
    public private(set) var selectedIndex: Int = 0
    public private(set) var objectMode: Bool = false
    public private(set) var objectActions: [ObjectAction] = []
    /// Index of the result that object-mode is acting on.
    public private(set) var objectTargetIndex: Int = 0

    public init(core: SummonCore) {
        self.core = core
    }

    public var selected: SearchResult? {
        guard !results.isEmpty, results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    public var objectTarget: SearchResult? {
        guard results.indices.contains(objectTargetIndex) else { return nil }
        return results[objectTargetIndex]
    }

    /// Pure search + alias/help merge. Safe off the main thread (no session mutation).
    public func computeResults(for raw: String) throws -> [SearchResult] {
        // Learned alias exact match elevates a synthetic top hit
        var list = try core.search.search(raw)
        let head = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !head.contains(" "), let alias = try core.aliases.get(keyword: head) {
            let kind = SearchResult.Kind(rawValue: alias.kind) ?? .command
            let hit = SearchResult(
                id: alias.targetResultID,
                title: alias.title,
                subtitle: "alias · \(alias.keyword)",
                kind: kind,
                path: alias.path,
                score: 1.0,
                payload: alias.payload ?? [:]
            )
            list.removeAll { $0.id == hit.id }
            list.insert(hit, at: 0)
        }
        // Help guide root
        if head == "?" || head == "help" {
            list = GuideContent.searchResults()
        }
        return list
    }

    /// Apply a precomputed list on the main thread (panel / table consumers).
    public func applyResults(_ raw: String, _ list: [SearchResult]) {
        query = raw
        objectMode = false
        objectActions = []
        results = list
        selectedIndex = 0
        objectTargetIndex = 0
    }

    @discardableResult
    public func setQuery(_ raw: String) throws -> [SearchResult] {
        let list = try computeResults(for: raw)
        applyResults(raw, list)
        return results
    }

    public func moveSelection(by delta: Int) {
        if objectMode {
            let count = objectActions.count
            guard count > 0 else { return }
            selectedIndex = (selectedIndex + delta + count) % count
        } else {
            guard !results.isEmpty else { return }
            selectedIndex = (selectedIndex + delta + results.count) % results.count
        }
    }

    /// Absolute selection (table click). Clamps to valid range.
    public func selectIndex(_ index: Int) {
        if objectMode {
            let count = objectActions.count
            guard count > 0 else { return }
            selectedIndex = min(max(0, index), count - 1)
        } else {
            guard !results.isEmpty else { return }
            selectedIndex = min(max(0, index), results.count - 1)
        }
    }

    /// Tab: enter object→action mode on the current result.
    public func enterObjectMode() {
        guard let item = selected else { return }
        objectTargetIndex = selectedIndex
        objectMode = true
        let favoriteState = try? core.favorites.contains(resultID: item.id)
        objectActions = ObjectActionGrammar.actions(for: item, isFavorite: favoriteState)
        selectedIndex = 0
    }

    public func exitObjectMode() {
        objectMode = false
        objectActions = []
        selectedIndex = objectTargetIndex
    }

    /// Return / primary action.
    @discardableResult
    public func confirm(actor: ActorTag = .user) throws -> String {
        try execute(prepareConfirmation(), actor: actor)
    }

    public func prepareConfirmation() throws -> LauncherConfirmation {
        if objectMode {
            guard objectActions.indices.contains(selectedIndex),
                  let target = objectTarget else {
                throw CoreError.store("no object action selected")
            }
            let action = objectActions[selectedIndex]
            return LauncherConfirmation(
                actionName: action.name,
                result: target,
                query: query,
                requiresUserConfirmation: action.isDestructive
            )
        }
        guard let item = selected else {
            throw CoreError.store("no selection")
        }
        let name = defaultActionName(for: item)
        let effectURL = item.payload["url"]?.stringValue ?? item.path
        return LauncherConfirmation(
            actionName: name,
            result: item,
            query: query,
            requiresUserConfirmation: effectURL.map(SystemEffects.requiresUserConfirmation) ?? false
        )
    }

    @discardableResult
    public func execute(
        _ confirmation: LauncherConfirmation,
        actor: ActorTag = .user
    ) throws -> String {
        let outcome = try core.invoke(
            actionName: confirmation.actionName,
            result: confirmation.result,
            actor: actor
        )
        switch outcome.outcome {
        case .applied:
            try? core.recordUsage(
                result: confirmation.result,
                query: confirmation.query,
                actor: actor
            )
            return confirmation.actionName
        case .rejected(let reason):
            throw CoreError.store("\(confirmation.actionName) rejected: \(reason)")
        case .staged(let proposalID):
            throw CoreError.store("\(confirmation.actionName) staged for approval as \(proposalID)")
        }
    }

    private func defaultActionName(for result: SearchResult) -> String {
        // Prefer explicit payload action (kill, screenshot, power modules, …)
        if case .string(let action) = result.payload["action"], !action.isEmpty {
            return action
        }
        switch result.kind {
        case .app: return "app.open"
        case .file, .folder: return "file.open"
        case .snippet, .calculation: return "snippet.copy"
        case .emoji: return "emoji.copy"
        case .clipboard: return "clipboard.copy"
        case .quicklink: return "quicklink.open"
        case .setting: return "settings.open"
        case .command: return "command.run"
        }
    }
}
