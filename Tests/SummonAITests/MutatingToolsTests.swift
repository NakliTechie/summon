import XCTest
@testable import SummonAI
import SummonCore

/// The staged-mutating-tools keystone: a mutating tool proposes a typed action,
/// the harness stages it (never executes), and only a human Accept applies it.
/// These are deterministic — they use a fake rung, not the live model.
final class MutatingToolsTests: XCTestCase {
    // MARK: - Intent gate

    func testMutatingIntentFiresOnImperativeCreateSnippet() {
        XCTAssertEqual(
            SystemReaders.mutatingIntents(for: "make a snippet called sig with my email"),
            [.createSnippet]
        )
        XCTAssertEqual(
            SystemReaders.mutatingIntents(for: "create a snippet for my address"),
            [.createSnippet]
        )
        XCTAssertEqual(
            SystemReaders.mutatingIntents(for: "save this as a snippet named addr"),
            [.createSnippet]
        )
        XCTAssertEqual(
            SystemReaders.mutatingIntents(for: "can you add a snippet keyword sig"),
            [.createSnippet]
        )
    }

    func testMutatingIntentStrippedForInformationQuestions() {
        // Question-form guardrail: informational queries never stage an action.
        XCTAssertTrue(SystemReaders.mutatingIntents(for: "what is a snippet").isEmpty)
        XCTAssertTrue(SystemReaders.mutatingIntents(for: "how do i create a snippet").isEmpty)
        XCTAssertTrue(SystemReaders.mutatingIntents(for: "tell me about snippets").isEmpty)
        XCTAssertTrue(SystemReaders.mutatingIntents(for: "why would i use a snippet").isEmpty)
        // World-knowledge / unrelated → no mutating tool.
        XCTAssertTrue(SystemReaders.mutatingIntents(for: "what is the capital of france").isEmpty)
        // Verb without the object → no snippet tool.
        XCTAssertTrue(SystemReaders.mutatingIntents(for: "make me a sandwich").isEmpty)
    }

    // MARK: - Collector

    func testCollectorRecordsAndDrainsOnce() {
        let collector = MutationCollector()
        XCTAssertTrue(collector.drain().isEmpty)
        collector.record(
            .snippetUpsert(id: "1", name: "sig", body: "hi", keyword: nil),
            summary: "Create snippet sig"
        )
        let drained = collector.drain()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.first?.action.name, "snippet.upsert")
        XCTAssertTrue(collector.drain().isEmpty, "drain must clear the collector")
    }

    // MARK: - Stage → Accept round trip

    func testProposedMutationStagesAsAgentActionAndAcceptApplies() async throws {
        let proposal = ProposedMutation(
            action: .snippetUpsert(id: "sig-1", name: "sig", body: "Best, Chirag", keyword: "sig"),
            summary: "Create snippet sig"
        )
        let ladder = AILadder.testing(
            fake: FakeModelRung(cannedText: "staged", cannedProposals: [proposal])
        )
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let service = SummonAIService(ladder: ladder, core: core)

        let response = try await service.respond(prompt: "make a snippet called sig", actor: .user)

        guard case let .staged(proposalID) = response.kind else {
            return XCTFail("expected staged, got \(response.kind)")
        }
        // Staged, not applied: the snippet does not exist yet (the invariant).
        XCTAssertTrue(try core.snippets.all().isEmpty)
        let staged = try core.staged.list(state: "staged")
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(staged.first?.rung, "agent")
        XCTAssertEqual(staged.first?.id, proposalID)
        // The staging is journaled as an audit.
        XCTAssertNotNil(try core.settings.get("ai.lastInvocation"))

        // Human accept applies the exact typed action.
        let reviewed = try XCTUnwrap(try core.staged.get(proposalID)).output
        let result = try core.acceptStagedAgentAction(
            id: proposalID, reviewedOutput: reviewed, actor: .user
        )
        guard case .applied = result.outcome else {
            return XCTFail("expected applied, got \(result.outcome)")
        }
        let snippets = try core.snippets.all()
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets.first?.name, "sig")
        XCTAssertEqual(snippets.first?.body, "Best, Chirag")
    }

    func testRespondNeverAutoAppliesAMutation() async throws {
        // Even a non-destructive create must stage — never auto-execute.
        let proposal = ProposedMutation(
            action: .snippetUpsert(id: "x", name: "n", body: "b", keyword: nil),
            summary: "Create snippet n"
        )
        let ladder = AILadder.testing(fake: FakeModelRung(cannedProposals: [proposal]))
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let service = SummonAIService(ladder: ladder, core: core)

        _ = try await service.respond(prompt: "create a snippet", actor: .user)

        XCTAssertTrue(try core.snippets.all().isEmpty, "a mutation must stage, not apply")
        XCTAssertEqual(try core.staged.list(state: "staged").count, 1)
    }

    func testRejectingAStagedMutationAppliesNothing() async throws {
        let proposal = ProposedMutation(
            action: .snippetUpsert(id: "y", name: "n", body: "b", keyword: nil),
            summary: "Create snippet n"
        )
        let ladder = AILadder.testing(fake: FakeModelRung(cannedProposals: [proposal]))
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let service = SummonAIService(ladder: ladder, core: core)

        let response = try await service.respond(prompt: "make a snippet", actor: .user)
        guard case let .staged(proposalID) = response.kind else {
            return XCTFail("expected staged, got \(response.kind)")
        }
        try core.rejectStagedAgentAction(id: proposalID, actor: .user)

        XCTAssertTrue(try core.snippets.all().isEmpty)
        XCTAssertEqual(try core.staged.get(proposalID)?.state, "rejected")
    }

    // MARK: - Ladder growth: quicklink + set-volume

    func testMutatingIntentCoversQuicklinkAndVolume() {
        XCTAssertEqual(
            SystemReaders.mutatingIntents(for: "make a quicklink for github called gh"),
            [.createQuicklink]
        )
        XCTAssertEqual(
            SystemReaders.mutatingIntents(for: "add a quick link named docs for docs.example.com"),
            [.createQuicklink]
        )
        XCTAssertEqual(SystemReaders.mutatingIntents(for: "set the volume to 30"), [.setVolume])
        XCTAssertEqual(SystemReaders.mutatingIntents(for: "change volume to 100"), [.setVolume])
        // Info-form and level-less volume invite nothing.
        XCTAssertTrue(SystemReaders.mutatingIntents(for: "what is the volume").isEmpty)
        XCTAssertTrue(SystemReaders.mutatingIntents(for: "turn up the volume").isEmpty)
    }

    func testQuicklinkMutationStagesAndAcceptApplies() async throws {
        let proposal = ProposedMutation(
            action: .quicklinkUpsert(id: "ql-1", name: "gh", url: "https://github.com", keyword: "gh"),
            summary: "Create quicklink gh"
        )
        let ladder = AILadder.testing(fake: FakeModelRung(cannedProposals: [proposal]))
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let service = SummonAIService(ladder: ladder, core: core)

        let response = try await service.respond(
            prompt: "make a quicklink for github called gh", actor: .user
        )
        guard case let .staged(proposalID) = response.kind else {
            return XCTFail("expected staged, got \(response.kind)")
        }
        XCTAssertTrue(try core.quicklinks.all().isEmpty)

        let reviewed = try XCTUnwrap(try core.staged.get(proposalID)).output
        let result = try core.acceptStagedAgentAction(
            id: proposalID, reviewedOutput: reviewed, actor: .user
        )
        guard case .applied = result.outcome else {
            return XCTFail("expected applied, got \(result.outcome)")
        }
        let links = try core.quicklinks.all()
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.name, "gh")
        XCTAssertEqual(links.first?.url, "https://github.com")
    }

    func testVolumeMutationStagesAsDecodableSystemEffect() async throws {
        // Stages a command.run system effect. Deliberately NOT accepted — accepting
        // would run osascript and change this host's volume.
        let url = "summon://system/set-volume/30"
        let proposal = ProposedMutation(
            action: .moduleRun(
                name: "command.run", targetID: "command:set-volume", path: url,
                payload: ["url": .string(url), "title": .string("Set volume to 30%")]
            ),
            summary: "Set volume to 30%"
        )
        let ladder = AILadder.testing(fake: FakeModelRung(cannedProposals: [proposal]))
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let service = SummonAIService(ladder: ladder, core: core)

        let response = try await service.respond(prompt: "set the volume to 30", actor: .user)
        guard case let .staged(proposalID) = response.kind else {
            return XCTFail("expected staged, got \(response.kind)")
        }
        let output = try XCTUnwrap(try core.staged.get(proposalID)).output
        let decoded = try SchemaGate().decodeReviewedAction(from: Data(output.utf8))
        guard case let .moduleRun(name, _, path, _) = decoded else {
            return XCTFail("expected moduleRun, got \(decoded)")
        }
        XCTAssertEqual(name, "command.run")
        XCTAssertEqual(path, url)
    }
}
