import Foundation

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

    @discardableResult
    public func setQuery(_ raw: String) throws -> [SearchResult] {
        query = raw
        objectMode = false
        objectActions = []
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
                score: 1.0
            )
            list.removeAll { $0.id == hit.id }
            list.insert(hit, at: 0)
        }
        // Help guide root
        if head == "?" || head == "help" {
            list = GuideContent.searchResults()
        }
        results = list
        selectedIndex = 0
        objectTargetIndex = 0
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

    /// Tab: enter object→action mode on the current result.
    public func enterObjectMode() {
        guard let item = selected else { return }
        objectTargetIndex = selectedIndex
        objectMode = true
        objectActions = ObjectActionGrammar.actions(for: item)
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
        if objectMode {
            guard objectActions.indices.contains(selectedIndex),
                  let target = objectTarget else {
                throw CoreError.store("no object action selected")
            }
            let action = objectActions[selectedIndex]
            try core.invoke(actionName: action.name, result: target, actor: actor)
            try? core.recordUsage(result: target, query: query)
            return action.name
        }
        guard let item = selected else {
            throw CoreError.store("no selection")
        }
        let name = defaultActionName(for: item)
        try core.invoke(actionName: name, result: item, actor: actor)
        try? core.recordUsage(result: item, query: query)
        return name
    }

    private func defaultActionName(for result: SearchResult) -> String {
        // Prefer explicit payload action (kill, screenshot, power modules, …)
        if case .string(let action) = result.payload["action"], !action.isEmpty {
            return action
        }
        switch result.kind {
        case .app: return "app.open"
        case .file, .folder: return "file.open"
        case .snippet, .calculation, .emoji: return "snippet.copy"
        case .clipboard: return "clipboard.copy"
        case .quicklink: return "quicklink.open"
        case .setting: return "settings.open"
        case .command: return "command.run"
        }
    }
}
