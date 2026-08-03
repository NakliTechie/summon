import Foundation

/// CI stand-in (READY-l1-hardware). Deterministic; no network.
public struct FakeModelRung: ModelRung, Sendable {
    public let id: ModelRungID = .fake
    public let displayName = "FakeModelRung"
    public var forcedAvailable: Bool
    public var cannedText: String

    public init(forcedAvailable: Bool = true, cannedText: String = "staged:ok") {
        self.forcedAvailable = forcedAvailable
        self.cannedText = cannedText
    }

    public func availability() async -> RungAvailability {
        forcedAvailable ? .available : .unavailable(reason: "forced unavailable")
    }

    public func complete(prompt: String) async throws -> ModelCompletion {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelRungError.emptyPrompt }
        guard forcedAvailable else {
            throw ModelRungError.unavailable(.fake, "forced unavailable")
        }
        return ModelCompletion(
            text: "\(cannedText) | echo:\(trimmed.prefix(120))",
            rung: .fake,
            egressSummary: ""
        )
    }
}
