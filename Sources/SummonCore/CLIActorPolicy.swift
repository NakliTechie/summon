import Foundation

/// Direct CLI operations that have not yet been routed through the action bus.
public enum CLIPrivilegedOperation: String, CaseIterable, Sendable {
    case proposalDecision
    case modelConsent
    case modelFetch
    case webSearch
    case ftsConsent
    case ftsConfiguration
    case ftsIndex
    case importData
    case exportFile
    case aliasMutation
    case favoriteMutation
}

public enum CLIActorPolicy {
    public static func authorizeAgentFace(
        actor: ActorTag,
        enabledValue: JSONValue?
    ) throws {
        guard actor == .agent else { return }
        guard enabledValue == .bool(true) else {
            throw CoreError.store(
                "agent CLI is disabled; enable \(AgentSocketServer.enabledSettingKey) as the user"
            )
        }
    }

    public static func authorize(
        actor: ActorTag,
        operation: CLIPrivilegedOperation
    ) throws {
        guard actor == .user else {
            throw CoreError.store(
                "\(operation.rawValue) requires the interactive user actor"
            )
        }
    }
}
