import Foundation
import SummonCore

/// Which mutating action a query invites. The classifier gate — the harness
/// (`SummonActionParser`) turns a matched intent into a typed `CoreAction` and
/// runs or stages it deterministically. Actions are never left to the on-device
/// model to call as a tool (it does so unreliably).
public enum MutatingToolIntent: String, Sendable, Hashable, CaseIterable {
    case createSnippet
    case createQuicklink
    case setVolume
}

extension SystemReaders {
    /// Which mutating actions a query invites. Two guardrails are baked in:
    /// - Question-form strip: informational queries (how/what/why…) invite nothing,
    ///   so "how do I make a snippet" teaches, it does not act.
    /// - Invite gate: an intent requires an explicit verb/object (or, for volume, a
    ///   target level) — this is where a future destructive intent would demand an
    ///   explicit destructive verb before it is ever offered.
    public static func mutatingIntents(for query: String) -> Set<MutatingToolIntent> {
        let q = query.lowercased()
        guard !isInformationQuestion(q) else { return [] }
        var result: Set<MutatingToolIntent> = []
        let createVerbs = [
            "make ", "create ", "save ", "add ", "new ", "store ", "set up ", "remember ",
        ]
        let hasCreateVerb = createVerbs.contains { q.contains($0) }
        if q.contains("snippet"), hasCreateVerb {
            result.insert(.createSnippet)
        }
        if q.contains("quicklink") || q.contains("quick link"), hasCreateVerb {
            result.insert(.createQuicklink)
        }
        // A level is required (a digit in the query) so there is a concrete target —
        // "turn up the volume" with no number invites nothing.
        if q.contains("volume"), q.contains(where: \.isNumber) {
            result.insert(.setVolume)
        }
        return result
    }

    /// A query that seeks information rather than commanding an action. Such queries
    /// invite no mutating action.
    static func isInformationQuestion(_ q: String) -> Bool {
        let infoPrefixes = [
            "how ", "what ", "what's", "why ", "when ", "where ", "which ",
            "who ", "explain", "define", "tell me", "is ", "are ", "does ", "do ",
        ]
        return infoPrefixes.contains { q.hasPrefix($0) }
    }
}
