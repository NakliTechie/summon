import Foundation

/// Agent-facing propose-only gate for destructive ops (RC-42, RC-59).
public enum DestructiveGuard {
    public static let destructiveActionNames: Set<String> = [
        "clipboard.delete",
        "snippet.delete",
        "quicklink.delete",
        "file.trash",
        "process.kill",
        "clipboard.clearUnpinned",
    ]

    public static func isDestructive(actionName: String) -> Bool {
        destructiveActionNames.contains(actionName)
    }

    public static func isDestructive(_ action: CoreAction) -> Bool {
        switch action {
        case .clipboardDelete, .snippetDelete, .quicklinkDelete:
            return true
        case .moduleRun(let name, _, _, let payload):
            if isDestructive(actionName: name) { return true }
            if case .bool(true) = payload["destructive"] { return true }
            return false
        default:
            return false
        }
    }

    /// Agents must not apply destructive actions directly — stage a proposal instead.
    public static func agentMayApply(actor: ActorTag, action: CoreAction) -> Bool {
        if actor != .agent { return true }
        return !isDestructive(action)
    }
}
