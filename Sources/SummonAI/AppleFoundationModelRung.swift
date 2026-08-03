import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// L1 adapter: Apple Foundation Models (`SystemLanguageModel` / `LanguageModelSession`).
/// Runtime detection only — never a build split or settings toggle (D3/D5).
@available(macOS 26.0, *)
public struct AppleFoundationModelRung: ModelRung, Sendable {
    public let id: ModelRungID = .l1Apple
    public let displayName = "Apple Foundation Models"

    public init() {}

    public func availability() async -> RungAvailability {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: Self.describe(reason))
        @unknown default:
            return .unavailable(reason: "unknown availability")
        }
        #else
        return .unavailable(reason: "FoundationModels framework not linked")
        #endif
    }

    public func complete(prompt: String) async throws -> ModelCompletion {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelRungError.emptyPrompt }

        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw ModelRungError.unavailable(.l1Apple, Self.describe(reason))
        @unknown default:
            throw ModelRungError.unavailable(.l1Apple, "unknown availability")
        }

        let session = LanguageModelSession(model: model, instructions: Self.systemInstructions)
        do {
            let response = try await session.respond(to: trimmed)
            return ModelCompletion(
                text: response.content,
                rung: .l1Apple,
                egressSummary: ""
            )
        } catch {
            throw ModelRungError.generationFailed(error.localizedDescription)
        }
        #else
        throw ModelRungError.unavailable(.l1Apple, "FoundationModels framework not linked")
        #endif
    }

    private static let systemInstructions = """
        You are the Summon launcher sidecar on the user's Mac.
        Be concise. Prefer a single command, short answer, or structured action.
        Never claim to have executed anything — Summon stages your output for the user.
        """

    #if canImport(FoundationModels)
    private static func describe(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "deviceNotEligible"
        case .appleIntelligenceNotEnabled:
            return "appleIntelligenceNotEnabled"
        case .modelNotReady:
            return "modelNotReady"
        @unknown default:
            return "unavailable"
        }
    }
    #endif
}

/// Pre–macOS 26 stand-in so call sites compile on package floor (14).
public struct UnavailableAppleFoundationModelRung: ModelRung, Sendable {
    public let id: ModelRungID = .l1Apple
    public let displayName = "Apple Foundation Models"

    public init() {}

    public func availability() async -> RungAvailability {
        .unavailable(reason: "requires macOS 26+ and Apple Intelligence hardware")
    }

    public func complete(prompt: String) async throws -> ModelCompletion {
        throw ModelRungError.unavailable(
            .l1Apple,
            "requires macOS 26+ and Apple Intelligence hardware"
        )
    }
}
