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
    // Destructive/disruptive system effects — recognized so they stage (amber Accept),
    // never fall through to a web search.
    case emptyTrash
    case sleepMac
    case lockScreen
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
        // Destructive/disruptive system effects (their own verbs, no create verb needed).
        let clearVerb = q.contains("empty") || q.contains("clear")
        if clearVerb, q.contains("trash") || q.contains("bin") {
            result.insert(.emptyTrash)
        }
        if q.contains("sleep"),
           q.contains("mac") || q.contains("computer") || q.hasPrefix("sleep") || q.contains("go to sleep") {
            result.insert(.sleepMac)
        }
        if q.contains("lock"), q.contains("screen") || q.contains("mac") || q.contains("computer") {
            result.insert(.lockScreen)
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
