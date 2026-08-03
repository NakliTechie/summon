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

    public static func defaultProductionRungs() -> [any ModelRung] {
        var list: [any ModelRung] = []
        if #available(macOS 26.0, *) {
            list.append(AppleFoundationModelRung())
        } else {
            list.append(UnavailableAppleFoundationModelRung())
        }
        return list
    }

    public static func testing(fake: FakeModelRung = FakeModelRung()) -> AILadder {
        AILadder(rungs: [fake])
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
        let preference: [ModelRungID] = [.l1Apple, .l0Packaged, .l2LocalRuntime, .l3BYOK, .fake]
        for id in preference {
            if let rung = rungs.first(where: { $0.id == id }) {
                if (await rung.availability()).isAvailable { return rung }
            }
        }
        return nil
    }

    public func complete(prompt: String) async throws -> ModelCompletion {
        guard let rung = await preferredRung() else {
            throw ModelRungError.unavailable(.l1Apple, "no AI rung available")
        }
        return try await rung.complete(prompt: prompt)
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
        staging.stage(proposal)
        if let core {
            _ = try? core.dispatch(
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
        }
        return proposal
    }
}
