import Foundation
import SummonCore

/// The two shapes AI output can take in the UI (the answer-vs-action split).
/// Kept AppKit-free and SummonAI-free so SummonUI still builds with AI removed.
public enum LauncherAIResponse: Sendable, Equatable {
    /// Plain text — rendered read-only (copy/insert), no Accept gate, executes nothing.
    case answer(text: String, rung: String, egressSummary: String)
    /// A destructive action — rendered as the amber Accept/Reject staged strip.
    case staged(proposalID: String, rung: String, egressSummary: String)
    /// A safe action the harness already ran — a truthful result, no gate.
    case performed(text: String)
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
    /// The user's explicit default-action preference: true = search-first,
    /// false = local-first, nil = auto (defer to sticky consent).
    private let searchDefaultIsPrimary: (@Sendable () -> Bool?)?
    /// True when the query is an action command ("set the volume to 30", "make a
    /// snippet") — such a query must stage, never web search, whatever the default.
    private let isActionQuery: (@Sendable (String) -> Bool)?
    /// Preload the model ahead of Enter (wired to the first keystroke of a query).
    private let prewarmHook: (@Sendable () -> Void)?

    public init(
        handler: @escaping @Sendable (String) async throws -> LauncherAIResponse,
        searchHandler: (@Sendable (String, Bool) async throws -> LauncherWebSearchResponse)? = nil,
        consentGranter: (@Sendable (Bool) -> Void)? = nil,
        consentIsSticky: (@Sendable () -> Bool)? = nil,
        searchDefaultIsPrimary: (@Sendable () -> Bool?)? = nil,
        isActionQuery: (@Sendable (String) -> Bool)? = nil,
        prewarm: (@Sendable () -> Void)? = nil
    ) {
        self.handler = handler
        self.searchHandler = searchHandler
        self.consentGranter = consentGranter
        self.consentIsSticky = consentIsSticky
        self.searchDefaultIsPrimary = searchDefaultIsPrimary
        self.isActionQuery = isActionQuery
        self.prewarmHook = prewarm
    }

    /// Best-effort model preload; safe to call on every relevant keystroke.
    public func prewarm() { prewarmHook?() }

    public func respond(prompt: String) async throws -> LauncherAIResponse {
        try await handler(prompt)
    }

    public var searchAvailable: Bool { searchHandler != nil }

    /// True once the user has granted sticky ("Always Allow") web consent. The
    /// local-first answer flow uses this to decide whether it may quietly consult
    /// the web in parallel — never egressing before that one-time opt-in.
    public var webConsentIsSticky: Bool { consentIsSticky?() ?? false }

    /// Which offer leads for a question. An explicit Preferences choice wins
    /// (search-first or local-first); with no choice (auto), search becomes
    /// primary once sticky ("Always") consent is granted — before that, local
    /// stays first so nothing egresses unasked.
    public var searchIsPrimary: Bool {
        if let explicit = searchDefaultIsPrimary?() { return explicit }
        return consentIsSticky?() ?? false
    }

    /// Both AI offers for a query, ordered so the primary (Enter) one is first.
    /// An action-shaped query always leads with "Ask local AI" so it routes to the
    /// staging path — a command like "set the volume to 30" must never be web-searched.
    public func offers(for rawQuery: String) -> [SearchResult] {
        let ask = offerResult(for: rawQuery)
        let search = searchOffer(for: rawQuery)
        let leadWithSearch = searchIsPrimary && !(isActionQuery?(rawQuery) ?? false)
        let ordered = leadWithSearch ? [search, ask] : [ask, search]
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
        // Once web consent is sticky, a question answers on-device first and then
        // quietly refines against the web — say so, so Enter's behavior is legible.
        let subtitle = webConsentIsSticky
            ? "On-device now · refines against the web · actions staged"
            : "Answers on-device · actions are staged for review"
        return SearchResult(
            id: "ai:ask:\(prompt)",
            title: "Ask local AI",
            subtitle: subtitle,
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
