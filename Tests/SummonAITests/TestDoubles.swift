import Foundation
@testable import SummonAI
import SummonCore

struct FakeModelRung: ModelRung, Sendable {
    let id: ModelRungID = .fake
    let displayName = "FakeModelRung"
    var forcedAvailable: Bool
    var cannedText: String
    var cannedProposals: [ProposedMutation]

    init(
        forcedAvailable: Bool = true,
        cannedText: String = "staged:ok",
        cannedProposals: [ProposedMutation] = []
    ) {
        self.forcedAvailable = forcedAvailable
        self.cannedText = cannedText
        self.cannedProposals = cannedProposals
    }

    func availability() async -> RungAvailability {
        forcedAvailable ? .available : .unavailable(reason: "forced unavailable")
    }

    func complete(prompt: String) async throws -> ModelCompletion {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelRungError.emptyPrompt }
        guard forcedAvailable else {
            throw ModelRungError.unavailable(.fake, "forced unavailable")
        }
        return ModelCompletion(
            text: "\(cannedText) | echo:\(trimmed.prefix(120))",
            rung: .fake,
            egressSummary: "",
            proposedActions: cannedProposals
        )
    }
}

struct FakeUnavailableL1: ModelRung, Sendable {
    let id: ModelRungID = .l1Apple
    let displayName = "Apple Foundation Models"

    func availability() async -> RungAvailability {
        .unavailable(reason: "deviceNotEligible")
    }

    func complete(prompt: String) async throws -> ModelCompletion {
        throw ModelRungError.unavailable(.l1Apple, "deviceNotEligible")
    }
}

extension AILadder {
    static func testingL0Fallback(
        l0: L0PackagedModelRung,
        l1Available: Bool = false
    ) -> AILadder {
        let l1: any ModelRung = l1Available
            ? FakeModelRung(cannedText: "L1")
            : FakeUnavailableL1()
        return AILadder(rungs: [l1, l0])
    }

    static func testing(fake: FakeModelRung = FakeModelRung()) -> AILadder {
        AILadder(rungs: [fake])
    }
}

final class MemoryL0WeightStore: L0WeightStore, @unchecked Sendable {
    private var storedConsent = L0Consent()
    private var weights: Set<String> = []
    private let lock = NSLock()

    var requiresInstalledManifestVerification: Bool { false }

    func consent() -> L0Consent {
        lock.lock()
        defer { lock.unlock() }
        return storedConsent
    }

    func setConsent(_ consent: L0Consent) throws {
        lock.lock()
        defer { lock.unlock() }
        storedConsent = consent
    }

    func markWeightsPresent(_ modelID: String) {
        lock.lock()
        defer { lock.unlock() }
        weights.insert(modelID)
    }

    func weightsPresent(for modelID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return weights.contains(modelID)
    }

    func weightsURL(for modelID: String) -> URL? {
        weightsPresent(for: modelID)
            ? URL(fileURLWithPath: "/tmp/summon-l0/\(modelID)")
            : nil
    }
}

struct FakeL0InferenceEngine: L0InferenceEngine, Sendable {
    func isReady(weightsURL: URL) -> Bool { true }

    func complete(prompt: String, weightsURL: URL) async throws -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return "L0-staged: \(trimmed.prefix(160))"
    }
}

struct QuickFixSidecar: Sendable {
    var rung: any ModelRung

    func rewrite(selection: String, tone: String = "clear") async throws -> PersistedStagedProposal {
        let prompt = "Rewrite the following text. Tone: \(tone). Return only the rewrite.\n\n\(selection)"
        let output = try await rung.complete(prompt: prompt)
        return PersistedStagedProposal(
            rung: rung.id.rawValue,
            prompt: prompt,
            output: output.text,
            egressSummary: output.egressSummary,
            state: "staged"
        )
    }
}

struct ScreenshotAskSidecar: Sendable {
    var rung: any ModelRung

    func ask(ocrText: String, question: String) async throws -> PersistedStagedProposal {
        let prompt = "Screenshot OCR:\n\(ocrText)\n\nQuestion: \(question)\nAnswer briefly."
        let output = try await rung.complete(prompt: prompt)
        return PersistedStagedProposal(
            rung: rung.id.rawValue,
            prompt: prompt,
            output: output.text,
            egressSummary: output.egressSummary,
            state: "staged"
        )
    }
}

struct TranslateSidecar: Sendable {
    var rung: any ModelRung

    func translate(text: String, to language: String) async throws -> PersistedStagedProposal {
        let prompt = "Translate to \(language). Return only the translation.\n\n\(text)"
        let output = try await rung.complete(prompt: prompt)
        return PersistedStagedProposal(
            rung: rung.id.rawValue,
            prompt: prompt,
            output: output.text,
            egressSummary: output.egressSummary,
            state: "staged"
        )
    }
}

struct DictationSidecar: Sendable {
    func stageTranscript(_ text: String) -> PersistedStagedProposal {
        PersistedStagedProposal(
            rung: "dictation",
            prompt: "(dictation)",
            output: text,
            egressSummary: "on-device",
            state: "staged"
        )
    }
}

struct NLSurfaceSidecar: Sendable {
    var rung: any ModelRung

    func shell(from natural: String) async throws -> PersistedStagedProposal {
        let prompt = """
        Convert to a single zsh command. Return only the command line, no markdown.
        Request: \(natural)
        """
        let output = try await rung.complete(prompt: prompt)
        return PersistedStagedProposal(
            rung: rung.id.rawValue,
            prompt: prompt,
            output: output.text.trimmingCharacters(in: .whitespacesAndNewlines),
            egressSummary: output.egressSummary,
            state: "staged"
        )
    }

    func calendar(from natural: String) async throws -> PersistedStagedProposal {
        let prompt = """
        Extract a calendar event as JSON with keys title, startISO, endISO.
        Request: \(natural)
        """
        let output = try await rung.complete(prompt: prompt)
        return PersistedStagedProposal(
            rung: rung.id.rawValue,
            prompt: prompt,
            output: output.text,
            egressSummary: output.egressSummary,
            state: "staged"
        )
    }
}

enum ExperimentalHashSemanticSearch {
    static func embed(_ text: String) -> [Double] {
        var vector = [Double](repeating: 0, count: 32)
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        for token in tokens {
            var hash = 0
            for scalar in token.unicodeScalars {
                hash = (hash &* 31 &+ Int(scalar.value)) & 0x7fffffff
            }
            vector[hash % 32] += 1
        }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            vector = vector.map { $0 / norm }
        }
        return vector
    }

    static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func rank(
        query: String,
        documents: [(id: String, text: String)],
        limit: Int = 20
    ) -> [(id: String, score: Double)] {
        let queryEmbedding = embed(query)
        return documents
            .map { ($0.id, cosine(queryEmbedding, embed($0.text))) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }
}
