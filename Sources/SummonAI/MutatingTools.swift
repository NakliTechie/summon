import Foundation
import SummonCore

/// Which mutating tool a query invites. The keystone of the answer-vs-action
/// split's action side: a matched intent attaches a propose-only tool that
/// stages a typed `CoreAction` for human Accept — it never executes.
public enum MutatingToolIntent: String, Sendable, Hashable, CaseIterable {
    case createSnippet
}

extension SystemReaders {
    /// Which mutating tools a query invites. Two guardrails are baked in:
    /// - Question-form strip: informational queries (how/what/why…) never get a
    ///   mutating tool, so "how do I make a snippet" teaches, it does not stage.
    /// - Invite gate: a mutating intent requires an explicit create verb plus its
    ///   object. This is where a future destructive tool would demand an explicit
    ///   destructive verb before it is ever offered.
    public static func mutatingIntents(for query: String) -> Set<MutatingToolIntent> {
        let q = query.lowercased()
        guard !isInformationQuestion(q) else { return [] }
        var result: Set<MutatingToolIntent> = []
        let createVerbs = [
            "make ", "create ", "save ", "add ", "new ", "store ", "set up ", "remember ",
        ]
        if q.contains("snippet"), createVerbs.contains(where: { q.contains($0) }) {
            result.insert(.createSnippet)
        }
        return result
    }

    /// A query that seeks information rather than commanding an action. Such
    /// queries are stripped of every mutating tool before the model sees them.
    static func isInformationQuestion(_ q: String) -> Bool {
        let infoPrefixes = [
            "how ", "what ", "what's", "why ", "when ", "where ", "which ",
            "who ", "explain", "define", "tell me", "is ", "are ", "does ", "do ",
        ]
        return infoPrefixes.contains { q.hasPrefix($0) }
    }
}

/// Per-invocation sink for mutating tool calls. A mutating FM tool records its
/// proposed action here instead of performing it; the rung drains the collector
/// after generation and the harness stages each proposal for human Accept. This
/// is the seam that keeps a mutating tool from ever executing during generation.
public final class MutationCollector: @unchecked Sendable {
    private var proposals: [ProposedMutation] = []
    private let lock = NSLock()

    public init() {}

    public func record(_ action: CoreAction, summary: String) {
        lock.lock(); defer { lock.unlock() }
        proposals.append(ProposedMutation(action: action, summary: summary))
    }

    public func drain() -> [ProposedMutation] {
        lock.lock(); defer { lock.unlock() }
        let out = proposals
        proposals.removeAll()
        return out
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// The first mutating tool (Macaw-parity action side). It NEVER creates a
/// snippet: it records a typed `snippetUpsert` proposal that the harness stages
/// for the user to review and accept. Reversible, local, non-destructive — the
/// safe first rung of the action ladder.
@available(macOS 26.0, *)
struct CreateSnippetTool: Tool {
    let name = "create_snippet"
    let description = "Stage a proposal to save a reusable text snippet on this Mac. "
        + "This does NOT create the snippet — it stages a proposal the user must "
        + "review and approve. Call it only when the user asks to make, create, "
        + "save, or add a snippet."

    let collector: MutationCollector

    @Generable
    struct Arguments {
        @Guide(description: "A short human name for the snippet.")
        var name: String
        @Guide(description: "The exact text the snippet expands to.")
        var body: String
        @Guide(description: "An optional keyword that triggers expansion; empty string if none.")
        var keyword: String
    }

    func call(arguments: Arguments) async throws -> String {
        let trimmedKeyword = arguments.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = CoreAction.snippetUpsert(
            id: UUID().uuidString,
            name: arguments.name,
            body: arguments.body,
            keyword: trimmedKeyword.isEmpty ? nil : trimmedKeyword
        )
        collector.record(action, summary: "Create snippet “\(arguments.name)”")
        return "Staged a proposal to create a snippet named \"\(arguments.name)\". "
            + "Tell the user it is staged for their review and approval. "
            + "Do NOT say it has been created, saved, or added."
    }
}

@available(macOS 26.0, *)
extension SummonToolbox {
    /// The mutating tools a query invites, each bound to `collector` so a call
    /// stages rather than executes. Empty for informational or non-action queries.
    static func mutatingTools(for query: String, collector: MutationCollector) -> [any Tool] {
        var tools: [any Tool] = []
        if SystemReaders.mutatingIntents(for: query).contains(.createSnippet) {
            tools.append(CreateSnippetTool(collector: collector))
        }
        return tools
    }
}
#endif
