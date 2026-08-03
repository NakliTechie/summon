import Foundation
import SummonCore

/// Stub UI door for C-spine: dispatches the same bus as CLI/hotkey with `actor=user`.
///
/// Not a real panel — proves the UI module path end-to-end without AppKit windows.
public struct StubLauncher: Sendable {
    public let core: SummonCore

    public init(core: SummonCore) {
        self.core = core
    }

    @discardableResult
    public func setSetting(key: String, value: JSONValue) throws -> ActionResult {
        try core.dispatch(
            action: .settingsSet(key: key, value: value),
            actor: .user
        )
    }

    @discardableResult
    public func deleteSetting(key: String) throws -> ActionResult {
        try core.dispatch(
            action: .settingsDelete(key: key),
            actor: .user
        )
    }

    public func getSetting(_ key: String) throws -> JSONValue? {
        try core.settings.get(key)
    }

    /// Launcher search door (same SearchService as CLI).
    public func search(_ query: String) throws -> [SearchResult] {
        try core.search.search(query)
    }

    /// Object→action list for a selected result (Tab grammar).
    public func actions(for result: SearchResult) -> [ObjectAction] {
        ObjectActionGrammar.actions(for: result)
    }

    @discardableResult
    public func upsertSnippet(id: String = UUID().uuidString, name: String, body: String, keyword: String? = nil) throws -> ActionResult {
        try core.dispatch(
            action: .snippetUpsert(id: id, name: name, body: body, keyword: keyword),
            actor: .user
        )
    }
}
