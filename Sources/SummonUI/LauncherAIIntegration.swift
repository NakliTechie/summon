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

/// Web search + on-device synthesis outcome (harness-driven), kept AI-free.
public enum LauncherWebSearchResponse: Sendable, Equatable {
    case answer(text: String, sources: [String], rung: String)
    case needsConsent(host: String)
    case noResults
    case unavailable
}

/// App-composed AI seam. SummonUI stays buildable when the optional SummonAI
/// target is removed, while the shipping app attaches the real ladder.
public struct LauncherAIIntegration: Sendable {
    private let handler: @Sendable (String) async throws -> LauncherAIResponse
    private let searchHandler: (@Sendable (String, Bool) async throws -> LauncherWebSearchResponse)?
    private let consentGranter: (@Sendable (Bool) -> Void)?
    private let consentIsSticky: (@Sendable () -> Bool)?

    public init(
        handler: @escaping @Sendable (String) async throws -> LauncherAIResponse,
        searchHandler: (@Sendable (String, Bool) async throws -> LauncherWebSearchResponse)? = nil,
        consentGranter: (@Sendable (Bool) -> Void)? = nil,
        consentIsSticky: (@Sendable () -> Bool)? = nil
    ) {
        self.handler = handler
        self.searchHandler = searchHandler
        self.consentGranter = consentGranter
        self.consentIsSticky = consentIsSticky
    }

    public func respond(prompt: String) async throws -> LauncherAIResponse {
        try await handler(prompt)
    }

    public var searchAvailable: Bool { searchHandler != nil }

    /// Once the user has granted sticky ("Always") web-search consent, search
    /// becomes the primary offer for a question — Enter searches directly (no
    /// re-prompt). Before that, local stays first so nothing egresses unasked.
    public var searchIsPrimary: Bool { consentIsSticky?() ?? false }

    /// Both AI offers for a query, ordered so the primary one is first.
    public func offers(for rawQuery: String) -> [SearchResult] {
        let ask = offerResult(for: rawQuery)
        let search = searchOffer(for: rawQuery)
        let ordered = searchIsPrimary ? [search, ask] : [ask, search]
        return ordered.compactMap { $0 }
    }

    public func search(prompt: String, allowOnce: Bool) async throws -> LauncherWebSearchResponse {
        guard let searchHandler else { return .unavailable }
        return try await searchHandler(prompt, allowOnce)
    }

    public func grantSearchConsent(always: Bool) { consentGranter?(always) }

    /// The "Search the web & answer" offer, shown only when search is wired.
    public func searchOffer(for rawQuery: String) -> SearchResult? {
        guard searchAvailable, let prompt = Self.prompt(from: rawQuery) else { return nil }
        return SearchResult(
            id: "web:search:\(prompt)",
            title: "Search the web & answer",
            subtitle: "Only your query leaves · answer composed on-device",
            kind: .command,
            score: 0.24,
            payload: [
                "action": .string("web.search"),
                "prompt": .string(prompt),
            ]
        )
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
