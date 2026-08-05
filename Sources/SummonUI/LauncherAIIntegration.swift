import Foundation
import SummonCore

public struct LauncherAIStageOutcome: Sendable, Equatable {
    public let proposalID: String
    public let rung: String
    public let egressSummary: String

    public init(proposalID: String, rung: String, egressSummary: String) {
        self.proposalID = proposalID
        self.rung = rung
        self.egressSummary = egressSummary
    }
}

/// App-composed AI seam. SummonUI stays buildable when the optional SummonAI
/// target is removed, while the shipping app can attach a real staged flow.
public struct LauncherAIIntegration: Sendable {
    private let stageHandler: @Sendable (String) async throws -> LauncherAIStageOutcome

    public init(
        stageHandler: @escaping @Sendable (String) async throws -> LauncherAIStageOutcome
    ) {
        self.stageHandler = stageHandler
    }

    public func stage(prompt: String) async throws -> LauncherAIStageOutcome {
        try await stageHandler(prompt)
    }

    public func offerResult(for rawQuery: String) -> SearchResult? {
        guard let prompt = Self.prompt(from: rawQuery) else { return nil }
        return SearchResult(
            id: "ai:stage:\(prompt)",
            title: "Stage with local AI",
            subtitle: "Review before accepting · unavailable rungs fail visibly",
            kind: .command,
            score: 0.25,
            payload: [
                "action": .string("ai.stage"),
                "prompt": .string(prompt),
            ]
        )
    }

    static func prompt(from rawQuery: String) -> String? {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        for prefix in ["ai:", "ask:"] where lower.hasPrefix(prefix) {
            let prompt = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return prompt.isEmpty ? nil : prompt
        }
        return trimmed.split(whereSeparator: \Character.isWhitespace).count >= 3
            ? trimmed
            : nil
    }
}
