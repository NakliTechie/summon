import Foundation

/// Universal AI rung seam (handoff §12). Floor is macOS 14; L1 is capability-gated.
/// Apple's FoundationModels APIs are adapters behind this protocol, never the core abstraction.
/// Stored in staged proposals and shown in `ai status`. Readable names replaced
/// `L0`/`L1`/`L2` on 2026-10-30; `StagedProposalStore.migrate()` rewrites old rows.
public enum ModelRungID: String, Sendable, Hashable, Codable, CaseIterable {
    case mlx = "mlx"
    case appleFM = "apple-fm"
    case localServer = "local-server"
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

public struct ModelCompletion: Sendable, Hashable, Equatable {
    public let text: String
    public let rung: ModelRungID
    /// What left the machine (egress honesty). Empty ⇒ fully on-device.
    public let egressSummary: String

    public init(text: String, rung: ModelRungID, egressSummary: String = "") {
        self.text = text
        self.rung = rung
        self.egressSummary = egressSummary
    }
}

public protocol ModelRung: Sendable {
    var id: ModelRungID { get }
    var displayName: String { get }
    func availability() async -> RungAvailability
    func complete(prompt: String) async throws -> ModelCompletion
    /// Preload model resources ahead of a likely request (e.g. on first keystroke).
    /// Best-effort and unguaranteed — it may leave the first `complete` no faster.
    /// No-op by default. See `AppleFoundationModelRung.prewarm`.
    func prewarm()
}

public extension ModelRung {
    func prewarm() {}
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
