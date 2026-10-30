import Foundation

/// Propose-only gate for destructive / elevated ops (RC-42, RC-59).
/// Non-user actors (agent, extension) must not apply these directly — stage for human accept.
public enum DestructiveGuard {
    public static func isDestructive(actionName: String) -> Bool {
        switch actionName {
        case "clipboard.delete", "snippet.delete", "quicklink.delete",
             "file.trash", "process.kill", "clipboard.clearUnpinned":
            return true
        default:
            return false
        }
    }

    /// System effects that destroy data or disrupt the machine (agent must not apply).
    public static func isSystemEffectURL(_ path: String?) -> Bool {
        guard let path, path.hasPrefix("summon://system/") else { return false }
        return true
    }

    /// Reversible, low-stakes system effects that are safe to run without a gate
    /// (set-volume, sleep-display, dark-mode). Everything else under
    /// summon://system/ (sleep, lock, empty-trash) stays destructive.
    public static func isSafeSystemEffect(_ path: String?) -> Bool {
        guard let path else { return false }
        let safe = [
            "summon://system/set-volume/",
            "summon://system/sleep-display",
            "summon://system/dark-mode",
        ]
        return safe.contains { path.hasPrefix($0) }
    }

    public static func isDestructive(_ action: CoreAction) -> Bool {
        switch action {
        case .clipboardDelete, .snippetDelete, .quicklinkDelete, .clipboardClearUnpinned,
             .aliasDelete, .favoriteRemove, .importReset:
            return true
        case .moduleRun(let name, _, let path, let payload):
            if isDestructive(actionName: name) { return true }
            if case .bool(true) = payload["destructive"] { return true }
            // command.run → empty-trash / sleep / lock are destructive; set-volume is not.
            if name == "command.run", isSystemEffectURL(path), !isSafeSystemEffect(path) {
                return true
            }
            if case .string(let url) = payload["url"], isSystemEffectURL(url),
               !isSafeSystemEffect(url) {
                return true
            }
            return false
        case .settingsSet, .settingsDelete, .snippetUpsert, .clipboardIngest, .clipboardIngestRich,
             .clipboardPin, .clipboardTouch, .clipboardIgnoreAdd, .clipboardIgnoreRemove,
             .quicklinkUpsert, .aliasSet, .favoriteAdd, .webConfigSet, .ftsConsentGrant,
             .ftsSetEnabled, .usageRecord, .frecencyRestore, .historyRestore,
             .stagedRestore, .modelConsentGrant,
             .proposalDecision,
             .agentSearch, .agentVersion,
             .agentCLI, .egressRequested, .extensionInstall, .extensionGrant:
            return false
        }
    }

    /// True when actor must stage (or be rejected) instead of applying.
    public static func requiresUserApproval(actor: ActorTag, action: CoreAction) -> Bool {
        switch actor {
        case .user, .system:
            return false
        case .agent:
            // Every agent write stages for the user (decided 2026-10-30); only the
            // journal notes of read-only agent commands apply directly.
            switch action {
            case .agentSearch, .agentVersion, .agentCLI:
                return false
            default:
                return true
            }
        case .ext:
            return extensionRequiresApproval(action)
        }
    }

    /// Settings keys an extension must not flip without user accept.
    public static let extensionRestrictedSettingsKeys: Set<String> = [
        "agent.socket.enabled",
        "web.search.enabled",
        "web.search.baseURL",
        "web.search.allowNonLoopback",
        "search.fts.enabled",
        "search.files.index.enabled",
        "launchAtLogin",
    ]

    public static func isExtensionRestrictedSettingKey(_ key: String) -> Bool {
        extensionRestrictedSettingsKeys.contains(key)
            || key.hasPrefix("web.search.") || key.hasPrefix("agent.")
    }

    /// Extensions (a development seam, not shipped) stage elevated ops only, so
    /// their own storage writes apply. Overwrites stage too (`ActionBus`).
    static func extensionRequiresApproval(_ action: CoreAction) -> Bool {
        if case .moduleRun = action { return true }
        if isDestructive(action) { return true }
        switch action {
        case .settingsSet(let key, _), .settingsDelete(let key):
            return isExtensionRestrictedSettingKey(key)
        case .clipboardIgnoreAdd, .clipboardIgnoreRemove, .aliasSet, .aliasDelete,
             .favoriteAdd, .favoriteRemove, .importReset, .webConfigSet, .ftsSetEnabled,
             .ftsConsentGrant, .modelConsentGrant, .egressRequested,
             .frecencyRestore, .historyRestore, .stagedRestore,
             .proposalDecision,
             .extensionInstall, .extensionGrant:
            return true
        default:
            return false
        }
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
