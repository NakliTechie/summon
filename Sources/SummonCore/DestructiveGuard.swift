import Foundation

/// Propose-only gate for destructive / elevated ops (RC-42, RC-59).
/// Non-user actors (agent, extension) must not apply these directly — stage for human accept.
public enum DestructiveGuard {
    public static let destructiveActionNames: Set<String> = [
        "clipboard.delete",
        "snippet.delete",
        "quicklink.delete",
        "file.trash",
        "process.kill",
        "clipboard.clearUnpinned",
        "command.run", // only when path is summon://system/* (see isDestructive)
    ]

    /// Settings keys agents/extensions must not flip without user accept.
    public static let restrictedSettingsKeys: Set<String> = [
        "agent.socket.enabled",
        "web.search.enabled",
        "web.search.baseURL",
        "search.fts.enabled",
    ]

    public static func isDestructive(actionName: String) -> Bool {
        switch actionName {
        case "clipboard.delete", "snippet.delete", "quicklink.delete",
             "file.trash", "process.kill", "clipboard.clearUnpinned":
            return true
        default:
            return false
        }
    }

    public static func isRestrictedSettingKey(_ key: String) -> Bool {
        if restrictedSettingsKeys.contains(key) { return true }
        if key.hasPrefix("web.search.") { return true }
        if key.hasPrefix("agent.") { return true }
        return false
    }

    /// System effects that destroy data or disrupt the machine (agent must not apply).
    public static func isSystemEffectURL(_ path: String?) -> Bool {
        guard let path, path.hasPrefix("summon://system/") else { return false }
        return true
    }

    public static func isDestructive(_ action: CoreAction) -> Bool {
        switch action {
        case .clipboardDelete, .snippetDelete, .quicklinkDelete, .clipboardClearUnpinned:
            return true
        case .moduleRun(let name, _, let path, let payload):
            if isDestructive(actionName: name) { return true }
            if case .bool(true) = payload["destructive"] { return true }
            // command.run → empty-trash / sleep / lock
            if name == "command.run", isSystemEffectURL(path) { return true }
            if case .string(let url) = payload["url"], isSystemEffectURL(url) { return true }
            return false
        case .settingsSet, .settingsDelete, .snippetUpsert, .clipboardIngest,
             .clipboardPin, .quicklinkUpsert:
            return false
        }
    }

    /// True when actor must stage (or be rejected) instead of applying.
    public static func requiresUserApproval(actor: ActorTag, action: CoreAction) -> Bool {
        guard actor.requiresProposeOnly else { return false }
        if isDestructive(action) { return true }
        switch action {
        case .settingsSet(let key, _):
            return isRestrictedSettingKey(key)
        case .settingsDelete(let key):
            return isRestrictedSettingKey(key)
        default:
            return false
        }
    }

    /// Agents/extensions must not apply destructive or restricted actions directly.
    public static func agentMayApply(actor: ActorTag, action: CoreAction) -> Bool {
        !requiresUserApproval(actor: actor, action: action)
    }
}

extension ActorTag {
    /// Agent and extension actors stage elevated ops; user/system apply.
    public var requiresProposeOnly: Bool {
        switch self {
        case .agent, .ext: return true
        case .user, .system: return false
        }
    }
}
