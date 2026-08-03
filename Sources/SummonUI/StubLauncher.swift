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
}
