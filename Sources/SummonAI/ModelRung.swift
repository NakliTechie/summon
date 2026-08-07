import Foundation
import SummonCore

/// Universal AI rung seam (handoff §12). Floor is macOS 14; L1 is capability-gated.
/// Apple's FoundationModels APIs are adapters behind this protocol, never the core abstraction.
public enum ModelRungID: String, Sendable, Hashable, Codable, CaseIterable {
    case l0Packaged = "L0"
    case l1Apple = "L1"
    case l2LocalRuntime = "L2"
    case l3BYOK = "L3"
    case fake = "fake"
}

public enum RungAvailability: Sendable, Hashable, Equatable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// A mutating action the model proposed via a staging tool this turn. The harness
/// stages each for explicit human Accept — the model never applies one, and never
/// truthfully claims it did (the anti-CLAIMS_DONE contract).
public struct ProposedMutation: Sendable, Hashable, Equatable {
    public let action: CoreAction
    public let summary: String

    public init(action: CoreAction, summary: String) {
        self.action = action
        self.summary = summary
    }
}

public struct ModelCompletion: Sendable, Hashable, Equatable {
    public let text: String
    public let rung: ModelRungID
    /// What left the machine (Sidecar honesty). Empty ⇒ fully on-device.
    public let egressSummary: String
    /// Mutating actions the model proposed this turn. Non-empty ⇒ the harness
    /// stages them for Accept instead of returning a plain answer.
    public let proposedActions: [ProposedMutation]

    public init(
        text: String,
        rung: ModelRungID,
        egressSummary: String = "",
        proposedActions: [ProposedMutation] = []
    ) {
        self.text = text
        self.rung = rung
        self.egressSummary = egressSummary
        self.proposedActions = proposedActions
    }
}

public protocol ModelRung: Sendable {
    var id: ModelRungID { get }
    var displayName: String { get }
    func availability() async -> RungAvailability
    func complete(prompt: String) async throws -> ModelCompletion
}

public enum ModelRungError: Error, Equatable, Sendable, LocalizedError {
    case unavailable(ModelRungID, String)
    case generationFailed(String)
    case emptyPrompt

    public var errorDescription: String? {
        switch self {
        case .unavailable(let id, let reason):
            return "\(id.rawValue) unavailable: \(reason)"
        case .generationFailed(let s):
            return s
        case .emptyPrompt:
            return "prompt must be non-empty"
        }
    }
}
