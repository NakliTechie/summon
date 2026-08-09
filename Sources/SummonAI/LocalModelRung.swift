import Foundation
import SummonCore

/// Tier-1 local model: a user-run OpenAI-compatible server (Ollama on :11434, LM
/// Studio on :1234) reachable over loopback. Silent — it detects a running server
/// and uses it, with no prompt and no config. Preferred over Apple Foundation
/// Models when present (a running server is the user's deliberate choice). Every
/// call is journaled as a `.localModel` egress; nothing leaves the machine.
public struct LocalModelRung: ModelRung, Sendable {
    public let id: ModelRungID = .l2LocalRuntime
    public let displayName = "Local model (Ollama / LM Studio)"

    private let core: SummonCore
    private let transport: any LocalModelTransport
    private let candidates: [URL]

    public init(
        core: SummonCore,
        transport: any LocalModelTransport = LiveLocalModelTransport(),
        candidates: [URL] = LocalModelRung.defaultCandidates()
    ) {
        self.core = core
        self.transport = transport
        self.candidates = candidates
    }

    public static func defaultCandidates() -> [URL] {
        ["http://127.0.0.1:11434/v1", "http://127.0.0.1:1234/v1"].compactMap { URL(string: $0) }
    }

    public func availability() async -> RungAvailability {
        if await resolve() != nil { return .available }
        return .unavailable(reason: "no local model server on :11434 (Ollama) or :1234 (LM Studio)")
    }

    public func complete(prompt: String) async throws -> ModelCompletion {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelRungError.emptyPrompt }
        guard let resolved = await resolve() else {
            throw ModelRungError.unavailable(.l2LocalRuntime, "no local model server running")
        }
        let auth = try authorize(resolved.base.appendingPathComponent("chat/completions"))
        do {
            let text = try await transport.chat(
                baseURL: resolved.base, model: resolved.model, prompt: trimmed, authorization: auth
            )
            return ModelCompletion(text: PromptLeakGuard.filter(text), rung: .l2LocalRuntime, egressSummary: "")
        } catch {
            throw ModelRungError.generationFailed(error.localizedDescription)
        }
    }

    /// First loopback candidate that lists a model → (baseURL, model). Silent probe.
    private func resolve() async -> (base: URL, model: String)? {
        for base in candidates {
            guard let auth = try? authorize(base.appendingPathComponent("models")),
                  let models = try? await transport.models(baseURL: base, authorization: auth),
                  let first = models.first else { continue }
            return (base, first)
        }
        return nil
    }

    private func authorize(_ url: URL) throws -> EgressAuthorization {
        let host = url.host ?? "127.0.0.1"
        let intent = try core.dispatch(
            action: .egressRequested(purpose: EgressPurpose.localModel.rawValue, host: host),
            actor: .user
        )
        guard let entry = try core.journal.entry(id: intent.envelopeID) else {
            throw ModelRungError.generationFailed("local-model egress intent missing after dispatch")
        }
        return try NetworkSovereignty.authorize(
            url: url, purpose: .localModel, actor: .user, journalEntry: entry
        )
    }
}
