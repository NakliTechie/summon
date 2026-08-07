import Foundation
import SummonCore

/// Detects which AI rungs are available. Never a settings screen — pure detection.
public final class AILadder: @unchecked Sendable {
    public private(set) var rungs: [any ModelRung]

    public init(rungs: [any ModelRung]? = nil) {
        if let rungs {
            self.rungs = rungs
        } else {
            self.rungs = Self.defaultProductionRungs()
        }
    }

    public static func defaultProductionRungs(modelsContainer: URL? = nil) -> [any ModelRung] {
        var list: [any ModelRung] = []
        // L1 first where hardware allows.
        if #available(macOS 26.0, *) {
            list.append(AppleFoundationModelRung())
        } else {
            list.append(UnavailableAppleFoundationModelRung())
        }
        // Experimental user-managed L0 MLX adapter (D7 interim decision).
        do {
            let store = try FileL0WeightStore(container: modelsContainer)
            list.append(L0PackagedModelRung.production(store: store))
        } catch {
            list.append(UnavailableProductionModelRung(
                id: .l0Packaged,
                displayName: "Experimental local MLX (L0)",
                reason: "model storage unavailable: \(error.localizedDescription)"
            ))
        }
        return list
    }

    public struct StatusRow: Sendable, Hashable, Equatable {
        public let id: ModelRungID
        public let displayName: String
        public let available: Bool
        public let detail: String
    }

    public func status() async -> [StatusRow] {
        var rows: [StatusRow] = []
        for rung in rungs {
            let avail = await rung.availability()
            switch avail {
            case .available:
                rows.append(StatusRow(
                    id: rung.id, displayName: rung.displayName,
                    available: true, detail: "available"
                ))
            case .unavailable(let reason):
                rows.append(StatusRow(
                    id: rung.id, displayName: rung.displayName,
                    available: false, detail: reason
                ))
            }
        }
        return rows
    }

    public func preferredRung() async -> (any ModelRung)? {
        let preference: [ModelRungID] = [.l1Apple, .l0Packaged, .fake]
        for id in preference {
            if let rung = rungs.first(where: { $0.id == id }) {
                if (await rung.availability()).isAvailable { return rung }
            }
        }
        return nil
    }

    public func complete(prompt: String) async throws -> ModelCompletion {
        guard let rung = await preferredRung() else {
            throw ModelRungError.unavailable(.l1Apple, "no AI rung available (L0 needs consent+weights)")
        }
        return try await rung.complete(prompt: prompt)
    }
}

private struct UnavailableProductionModelRung: ModelRung, Sendable {
    let id: ModelRungID
    let displayName: String
    let reason: String

    func availability() async -> RungAvailability {
        .unavailable(reason: reason)
    }

    func complete(prompt: String) async throws -> ModelCompletion {
        throw ModelRungError.unavailable(id, reason)
    }
}

/// Staged AI output (propose-don't-dispose). Never auto-executed.
public struct StagedAIProposal: Sendable, Hashable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let rung: ModelRungID
    public let prompt: String
    public let output: String
    public let egressSummary: String
    public var state: State

    public enum State: String, Sendable, Hashable, Codable, Equatable {
        case staged
        case accepted
        case rejected
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rung: ModelRungID,
        prompt: String,
        output: String,
        egressSummary: String,
        state: State = .staged
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rung = rung
        self.prompt = prompt
        self.output = output
        self.egressSummary = egressSummary
        self.state = state
    }
}

public final class AIStagingStore: @unchecked Sendable {
    private var items: [UUID: StagedAIProposal] = [:]
    private let lock = NSLock()

    public init() {}

    public func stage(_ proposal: StagedAIProposal) {
        lock.lock(); defer { lock.unlock() }
        items[proposal.id] = proposal
    }

    public func get(_ id: UUID) -> StagedAIProposal? {
        lock.lock(); defer { lock.unlock() }
        return items[id]
    }

    public func allStaged() -> [StagedAIProposal] {
        lock.lock(); defer { lock.unlock() }
        return items.values.filter { $0.state == .staged }.sorted { $0.createdAt > $1.createdAt }
    }

    public func accept(_ id: UUID) -> StagedAIProposal? {
        lock.lock(); defer { lock.unlock() }
        guard var p = items[id], p.state == .staged else { return nil }
        p.state = .accepted
        items[id] = p
        return p
    }

    public func reject(_ id: UUID) -> StagedAIProposal? {
        lock.lock(); defer { lock.unlock() }
        guard var p = items[id], p.state == .staged else { return nil }
        p.state = .rejected
        items[id] = p
        return p
    }
}

/// Day-1 AI face: ladder + staging. Journals via SummonCore when present.
/// The two shapes an AI invocation can resolve to (the answer-vs-action split).
public struct AIResponse: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Plain text — displayed read-only; executes nothing, so it is not staged.
        case answer(text: String)
        /// A destructive action — staged for explicit Accept/Reject.
        case staged(proposalID: String)
        /// A safe, reversible action the harness already ran — a truthful result.
        case performed(text: String)
    }
    public let kind: Kind
    public let rung: ModelRungID
    public let egressSummary: String

    public init(kind: Kind, rung: ModelRungID, egressSummary: String) {
        self.kind = kind
        self.rung = rung
        self.egressSummary = egressSummary
    }
}

/// Result of a harness-driven web search + on-device synthesis.
public enum WebSearchOutcome: Sendable, Equatable {
    case answer(text: String, rung: ModelRungID, sources: [WebHit])
    case needsConsent(host: String)
    case disabled
    case noResults
}

public final class SummonAIService: @unchecked Sendable {
    public let ladder: AILadder
    public let staging: AIStagingStore
    public let core: SummonCore?

    public init(
        ladder: AILadder = AILadder(),
        staging: AIStagingStore = AIStagingStore(),
        core: SummonCore? = nil
    ) {
        self.ladder = ladder
        self.staging = staging
        self.core = core
    }

    public func completeAndStage(
        prompt: String,
        actor: ActorTag = .user
    ) async throws -> StagedAIProposal {
        let completion = try await ladder.complete(prompt: prompt)
        let proposal = StagedAIProposal(
            rung: completion.rung,
            prompt: prompt,
            output: completion.text,
            egressSummary: completion.egressSummary
        )
        if let core {
            try core.staged.migrate()
            try core.staged.upsert(PersistedStagedProposal(
                id: proposal.id.uuidString,
                createdAt: proposal.createdAt,
                rung: completion.rung.rawValue,
                prompt: prompt,
                output: completion.text,
                egressSummary: completion.egressSummary,
                state: "staged"
            ))
            do {
                _ = try core.dispatch(
                    action: .settingsSet(
                        key: "ai.lastInvocation",
                        value: .object([
                            "rung": .string(completion.rung.rawValue),
                            "egress": .string(completion.egressSummary),
                            "proposalID": .string(proposal.id.uuidString),
                            "promptChars": .number(Double(prompt.count)),
                        ])
                    ),
                    actor: actor
                )
            } catch let dispatchError {
                do {
                    try core.staged.delete(id: proposal.id.uuidString)
                } catch let rollbackError {
                    throw CoreError.store(
                        "AI invocation audit failed: \(dispatchError.localizedDescription); "
                            + "proposal rollback failed: \(rollbackError.localizedDescription)"
                    )
                }
                throw dispatchError
            }
        } else {
            staging.stage(proposal)
        }
        return proposal
    }

    /// Answer path of the answer-vs-action split. With no tools wired, every model
    /// completion is a plain answer: it executes nothing, so it is NOT staged — it
    /// is returned for read-only display. The invocation is still journaled as an
    /// audit. When tool-use lands (Chunk D), a model tool call routes to the staged
    /// action path (`completeAndStage`) instead.
    public func respond(
        prompt: String,
        actor: ActorTag = .user
    ) async throws -> AIResponse {
        // Action commands are harness-driven: parse the typed action deterministically,
        // then do the safe thing or stage the destructive one. The model is never
        // asked to act, so it can never fail to call a tool or claim it did.
        if let action = SummonActionParser.parse(prompt) {
            return try performOrStage(action, prompt: prompt, actor: actor)
        }
        // A clearly-unsupported action command gets a deterministic, honest decline —
        // the model is not asked, so it can't offer to "help" with what Summon can't do.
        if let reason = SummonActionParser.declineReason(prompt) {
            return AIResponse(kind: .answer(text: reason), rung: .l1Apple, egressSummary: "")
        }
        let completion = try await ladder.complete(prompt: prompt)
        if let core {
            _ = try core.dispatch(
                action: .settingsSet(
                    key: "ai.lastInvocation",
                    value: .object([
                        "rung": .string(completion.rung.rawValue),
                        "egress": .string(completion.egressSummary),
                        "kind": .string("answer"),
                        "promptChars": .number(Double(prompt.count)),
                    ])
                ),
                actor: actor
            )
        }
        return AIResponse(
            kind: .answer(text: completion.text),
            rung: completion.rung,
            egressSummary: completion.egressSummary
        )
    }

    /// Do-safe / stage-destructive. A reversible action runs immediately (actor
    /// `.user`) and returns a truthful result; a destructive one is staged for
    /// Accept. The harness performs and reports — the model never claims it acted.
    private func performOrStage(
        _ action: CoreAction,
        prompt: String,
        actor: ActorTag
    ) throws -> AIResponse {
        if DestructiveGuard.isDestructive(action) {
            let id = try stageAction(action, prompt: prompt, actor: actor)
            return AIResponse(kind: .staged(proposalID: id), rung: .l1Apple, egressSummary: "")
        }
        guard let core else {
            return AIResponse(
                kind: .answer(text: "That action isn't available in this build."),
                rung: .l1Apple, egressSummary: ""
            )
        }
        let result = try core.dispatch(action: action, actor: actor)
        switch result.outcome {
        case .applied:
            return AIResponse(
                kind: .performed(text: Self.performedSummary(action)),
                rung: .l1Apple, egressSummary: ""
            )
        case .rejected(let reason):
            return AIResponse(
                kind: .answer(text: "Couldn't do that: \(reason)"),
                rung: .l1Apple, egressSummary: ""
            )
        case .staged(let proposalID):
            return AIResponse(kind: .staged(proposalID: proposalID), rung: .l1Apple, egressSummary: "")
        }
    }

    /// Stages a destructive action as an agent-rung proposal (the amber Accept path),
    /// journals it, notifies observers, and rolls back if the audit write fails.
    private func stageAction(_ action: CoreAction, prompt: String, actor: ActorTag) throws -> String {
        guard let core else {
            let proposal = StagedAIProposal(
                rung: .l1Apple, prompt: prompt,
                output: (try? SchemaGate().reviewedText(for: action)) ?? action.name,
                egressSummary: ""
            )
            staging.stage(proposal)
            return proposal.id.uuidString
        }
        try core.staged.migrate()
        let reviewedText = try SchemaGate().reviewedText(for: action)
        let proposalID = UUID().uuidString
        try core.staged.upsert(PersistedStagedProposal(
            id: proposalID, rung: "agent", prompt: prompt,
            output: reviewedText, egressSummary: "local-stage", state: "staged"
        ))
        do {
            _ = try core.dispatch(
                action: .settingsSet(key: "ai.lastInvocation", value: .object([
                    "kind": .string("staged-action"),
                    "action": .string(action.name),
                    "proposalID": .string(proposalID),
                ])),
                actor: actor
            )
        } catch {
            try? core.staged.delete(id: proposalID)
            throw error
        }
        NotificationCenter.default.post(
            name: .summonStagedProposalDidChange, object: nil,
            userInfo: ["proposalID": proposalID]
        )
        return proposalID
    }

    /// Truthful past-tense summary of an action the harness just applied.
    static func performedSummary(_ action: CoreAction) -> String {
        switch action {
        case .moduleRun(_, _, let path, let payload):
            if let path, path.contains("set-volume/"), let level = path.split(separator: "/").last {
                return "Volume set to \(level)%."
            }
            if case .string(let title) = payload["title"] { return title }
            return "Done."
        case .snippetUpsert(_, let name, _, _):
            return "Snippet “\(name)” saved."
        case .quicklinkUpsert(_, let name, _, _):
            return "Quicklink “\(name)” saved."
        default:
            return "Done."
        }
    }

    // MARK: - Web search (harness-driven: consent → egress-gated fetch → RAG)

    /// The user's explicit default-action preference for a question:
    /// true = web-search-first, false = local-answer-first, nil = auto (defer to
    /// sticky consent). Backs `LauncherAIIntegration.searchIsPrimary`.
    public func searchDefaultIsPrimary() -> Bool? {
        guard let core, let value = (try? core.settings.get("search.defaultAction")) ?? nil else {
            return nil
        }
        switch value.stringValue {
        case "search": return true
        case "local": return false
        default: return nil
        }
    }

    public func webSearchConsentGranted() -> Bool {
        guard let core,
              let value = (try? core.settings.get("web.search.consentAlways")) ?? nil
        else { return false }
        return value.boolValue == true
    }

    public func grantWebSearchConsentAlways(actor: ActorTag = .user) throws {
        guard let core else { return }
        _ = try core.dispatch(
            action: .settingsSet(key: "web.search.consentAlways", value: .bool(true)),
            actor: actor
        )
    }

    /// Answer a query by searching the web and synthesizing on-device (the
    /// Google-style summary). Harness-driven: consent is checked up front — no
    /// mid-generation prompt — egress is journaled per call, and only the query
    /// leaves; the answer is composed locally from the returned passages.
    public func searchAndAnswer(
        query: String,
        provider: AuthorizedWebSearchProvider,
        allowOnce: Bool = false,
        actor: ActorTag = .user
    ) async throws -> WebSearchOutcome {
        guard let core, core.webConfig.enabled else { return .disabled }
        guard allowOnce || webSearchConsentGranted() else {
            return .needsConsent(host: provider.host)
        }
        let host = provider.host.lowercased()
        guard !host.isEmpty, let url = URL(string: "https://\(host)/") else { return .disabled }

        let intent = try core.dispatch(
            action: .egressRequested(purpose: EgressPurpose.userWeb.rawValue, host: host),
            actor: actor
        )
        guard let entry = try core.journal.entry(id: intent.envelopeID) else {
            throw CoreError.journal("web egress intent missing after dispatch")
        }
        let authorization = try NetworkSovereignty.authorize(
            url: url, purpose: .userWeb, actor: actor, journalEntry: entry
        )
        let hits = try await provider.search(
            query: WebEnrich.searchQuery(from: query), limit: 5, authorization: authorization
        )
        guard !hits.isEmpty else { return .noResults }
        let completion = try await ladder.complete(
            prompt: WebEnrich.enrichPrompt(question: query, hits: hits)
        )
        return .answer(text: completion.text, rung: completion.rung, sources: hits)
    }

    public func accept(id: UUID, actor: ActorTag = .user) throws -> StagedAIProposal? {
        if let core {
            guard let persisted = try core.staged.get(id.uuidString),
                  persisted.state == "staged" else { return nil }
            try core.acceptStagedTextProposal(
                id: id.uuidString,
                reviewedOutput: persisted.output,
                actor: actor
            )
            return Self.proposal(from: persisted, state: .accepted)
        }
        return staging.accept(id)
    }

    public func reject(id: UUID, actor: ActorTag = .user) throws -> StagedAIProposal? {
        if let core {
            guard let persisted = try core.staged.get(id.uuidString),
                  persisted.state == "staged" else { return nil }
            try core.rejectStagedProposal(id: id.uuidString, actor: actor)
            return Self.proposal(from: persisted, state: .rejected)
        }
        return staging.reject(id)
    }

    private static func proposal(
        from persisted: PersistedStagedProposal,
        state: StagedAIProposal.State
    ) -> StagedAIProposal? {
        guard let id = UUID(uuidString: persisted.id),
              let rung = ModelRungID(rawValue: persisted.rung) else {
            return nil
        }
        return StagedAIProposal(
            id: id,
            createdAt: persisted.createdAt,
            rung: rung,
            prompt: persisted.prompt,
            output: persisted.output,
            egressSummary: persisted.egressSummary,
            state: state
        )
    }
}
