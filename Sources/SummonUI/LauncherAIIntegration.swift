import Foundation
import SummonCore

/// The two shapes AI output can take in the UI (the answer-vs-action split).
/// Kept AppKit-free and SummonAI-free so SummonUI still builds with AI removed.
public enum LauncherAIResponse: Sendable, Equatable {
    /// Plain text — rendered read-only (copy/insert), no Accept gate, executes nothing.
    case answer(text: String, rung: String, egressSummary: String)
    /// A machine action — rendered as the amber Accept/Reject staged strip.
    case staged(proposalID: String, rung: String, egressSummary: String)
}

/// App-composed AI seam. SummonUI stays buildable when the optional SummonAI
/// target is removed, while the shipping app attaches the real ladder.
public struct LauncherAIIntegration: Sendable {
    private let handler: @Sendable (String) async throws -> LauncherAIResponse

    public init(
        handler: @escaping @Sendable (String) async throws -> LauncherAIResponse
    ) {
        self.handler = handler
    }

    public func respond(prompt: String) async throws -> LauncherAIResponse {
        try await handler(prompt)
    }

    public func offerResult(for rawQuery: String) -> SearchResult? {
        guard let prompt = Self.prompt(from: rawQuery) else { return nil }
        return SearchResult(
            id: "ai:ask:\(prompt)",
            title: "Ask local AI",
            subtitle: "Answers on-device · actions are staged for review",
            kind: .command,
            score: 0.25,
            payload: [
                "action": .string("ai.ask"),
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
