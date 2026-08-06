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

        let session = LanguageModelSession(
            model: model,
            tools: SummonToolbox.tools(for: trimmed),
            instructions: Self.systemInstructions
        )
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
        You are the Summon launcher sidecar on the user's Mac. Be concise.
        Tools report this Mac's live state. Call a tool ONLY when the user's \
        request is specifically about that tool's subject:
        - battery_status: only for battery, charge, or power questions.
        - current_datetime: only for the current date, day, or time.
        - system_info: only for macOS version, memory, CPU, thermal, or uptime.
        Never call a tool to pad an unrelated answer, and never append tool \
        output the user did not ask for. If the request is about none of these \
        subjects, answer directly and call no tool.
        You cannot perform actions or access anything else on this Mac. Never \
        claim to have done something. Do not invent facts — versions, dates, \
        events, or results — and if you are unsure, say so plainly.
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
