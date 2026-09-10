import XCTest
@testable import SummonAI
import SummonCore
import GRDB

final class AILadderTests: XCTestCase {
    func testFakeRungCompleteAndStage() async throws {
        let ladder = AILadder.testing(fake: FakeModelRung(cannedText: "unit"))
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let service = SummonAIService(ladder: ladder, core: core)
        let proposal = try await service.completeAndStage(prompt: "hello world", actor: .user)
        XCTAssertEqual(proposal.state, .staged)
        XCTAssertEqual(proposal.rung, .fake)
        XCTAssertTrue(proposal.output.contains("unit"))
        XCTAssertTrue(service.staging.allStaged().isEmpty)
        XCTAssertEqual(try core.staged.get(proposal.id.uuidString)?.state, "staged")
        XCTAssertEqual(try service.accept(id: proposal.id)?.state, .accepted)
        XCTAssertTrue(service.staging.allStaged().isEmpty)
    }

    func testRespondReturnsAnswerWithoutStaging() async throws {
        let ladder = AILadder.testing(fake: FakeModelRung(cannedText: "answer-text"))
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let service = SummonAIService(ladder: ladder, core: core)

        let response = try await service.respond(prompt: "a plain question", actor: .user)

        guard case let .answer(text) = response.kind else {
            return XCTFail("expected answer, got \(response.kind)")
        }
        XCTAssertTrue(text.contains("answer-text"))
        XCTAssertEqual(response.rung, .fake)
        // An answer executes nothing, so it must NOT create a staged proposal.
        XCTAssertTrue(try core.staged.list(state: nil).isEmpty)
        // The invocation is still journaled as an audit.
        XCTAssertNotNil(try core.settings.get("ai.lastInvocation"))
    }

    func testServiceAcceptAndRejectUseTransactionalDecisionJournal() async throws {
        let ladder = AILadder.testing(fake: FakeModelRung(cannedText: "unit"))
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let service = SummonAIService(ladder: ladder, core: core)
        let accepted = try await service.completeAndStage(prompt: "accept", actor: .user)
        let rejected = try await service.completeAndStage(prompt: "reject", actor: .user)

        XCTAssertEqual(try service.accept(id: accepted.id, actor: .user)?.state, .accepted)
        XCTAssertEqual(try service.reject(id: rejected.id, actor: .user)?.state, .rejected)

        XCTAssertEqual(try core.staged.get(accepted.id.uuidString)?.state, "accepted")
        XCTAssertEqual(try core.staged.get(rejected.id.uuidString)?.state, "rejected")
        let decisions = try core.journal.allEntries().compactMap { entry -> String? in
            guard case .proposalDecision(_, let state, _) = entry.action else { return nil }
            return state
        }
        XCTAssertEqual(decisions, ["accepted", "rejected"])
    }

    func testAuditFailureRemovesPersistedProposal() async throws {
        let ladder = AILadder.testing(fake: FakeModelRung(cannedText: "unit"))
        let core = try SummonCore.inMemory(appSearchPaths: [])
        try await core.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_ai_invocation_audit
                BEFORE INSERT ON action_journal
                WHEN NEW.action_json LIKE '%ai.lastInvocation%'
                BEGIN
                  SELECT RAISE(FAIL, 'injected AI invocation audit failure');
                END;
                """)
        }
        let service = SummonAIService(ladder: ladder, core: core)

        do {
            _ = try await service.completeAndStage(prompt: "rollback", actor: .user)
            XCTFail("expected audit failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("injected AI invocation audit failure"))
        }

        XCTAssertTrue(try core.staged.list(state: nil).isEmpty)
        XCTAssertNil(try core.settings.get("ai.lastInvocation"))
    }

    func testSearchAndAnswerSynthesizesFromProviderHitsWhenConsented() async throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        core.webConfig.enabled = true
        let service = SummonAIService(
            ladder: .testing(fake: FakeModelRung(cannedText: "SYNTHESIZED")),
            core: core
        )
        try service.grantWebSearchConsentAlways()
        let provider = FakeAuthorizedWebSearchProvider(
            host: "example.com",
            hits: [WebHit(title: "Canberra", url: "https://example.com/c", snippet: "capital")]
        )

        let outcome = try await service.searchAndAnswer(query: "capital of australia", provider: provider)

        guard case let .answer(text, rung, sources, note) = outcome else {
            return XCTFail("expected answer, got \(outcome)")
        }
        XCTAssertNil(note, "the configured provider answered; no fallback note")
        XCTAssertTrue(text.contains("SYNTHESIZED"))
        XCTAssertEqual(rung, .fake)
        XCTAssertEqual(sources.count, 1)
        // Egress was journaled for the provider host (audit trail).
        let egress = try core.journal.allEntries().contains { entry in
            if case .egressRequested(let purpose, let host) = entry.action {
                return purpose == "user.web" && host == "example.com"
            }
            return false
        }
        XCTAssertTrue(egress)
    }

    /// harden 2026-09-10 F7: a configured provider that fails must not be presented
    /// as if it had answered. The fallback answer names the failed provider and the
    /// host that actually answered. No network: the fallback is an injected fake.
    func testSearchAndAnswerFallbackNamesTheFailedProvider() async throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        core.webConfig.enabled = true
        let service = SummonAIService(
            ladder: .testing(fake: FakeModelRung(cannedText: "FROM FALLBACK")),
            core: core
        )
        try service.grantWebSearchConsentAlways()
        service.fallbackProvider = FakeAuthorizedWebSearchProvider(
            host: "fallback.example",
            hits: [WebHit(title: "Floor", url: "https://fallback.example/f", snippet: "floor hit")]
        )
        let broken = FakeAuthorizedWebSearchProvider(
            host: "127.0.0.1", hits: [], failure: .network("HTTP 500")
        )

        let outcome = try await service.searchAndAnswer(query: "hello", provider: broken)

        guard case let .answer(text, _, sources, note) = outcome else {
            return XCTFail("expected a fallback answer, got \(outcome)")
        }
        XCTAssertTrue(text.contains("FROM FALLBACK"))
        XCTAssertEqual(sources.map(\.url), ["https://fallback.example/f"])
        let note0 = try XCTUnwrap(note, "fallback answers must carry a note naming the failed provider")
        XCTAssertTrue(note0.contains("127.0.0.1"), note0)
        XCTAssertTrue(note0.contains("HTTP 500"), note0)
        XCTAssertTrue(note0.contains("fallback.example"), note0)
        // Both egress intents are journaled: the failed provider and the fallback host.
        let hosts = try core.journal.allEntries().compactMap { entry -> String? in
            if case .egressRequested(_, let host) = entry.action { return host }
            return nil
        }
        XCTAssertEqual(hosts, ["127.0.0.1", "fallback.example"])
    }

    func testSearchAndAnswerReturnsResultsWhenNoModelAvailable() async throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        core.webConfig.enabled = true
        // No rungs → ladder.complete throws, mimicking a Mac without Apple Intelligence.
        let service = SummonAIService(ladder: AILadder(rungs: []), core: core)
        try service.grantWebSearchConsentAlways()
        let provider = FakeAuthorizedWebSearchProvider(
            host: "example.com",
            hits: [
                WebHit(title: "Mac Studio", url: "https://example.com/ms", snippet: "release timing"),
                WebHit(title: "Rumor roundup", url: "https://example.com/r", snippet: "expected soon"),
            ]
        )

        let outcome = try await service.searchAndAnswer(query: "when will the mac studio ship", provider: provider)

        guard case let .answer(text, _, sources, _) = outcome else {
            return XCTFail("expected an answer with results, got \(outcome)")
        }
        XCTAssertEqual(sources.count, 2, "fetched web results are returned even without a model")
        XCTAssertFalse(text.isEmpty)
    }

    func testSearchAndAnswerNeedsConsentThenAllowOnceBypasses() async throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        core.webConfig.enabled = true
        let service = SummonAIService(ladder: .testing(fake: FakeModelRung(cannedText: "S")), core: core)
        let provider = FakeAuthorizedWebSearchProvider(host: "example.com")

        // No consent → asks.
        let asked = try await service.searchAndAnswer(query: "x", provider: provider)
        XCTAssertEqual(asked, .needsConsent(host: "example.com"))

        // allow-once bypasses without persisting.
        let once = try await service.searchAndAnswer(query: "x", provider: provider, allowOnce: true)
        if case .answer = once {} else { XCTFail("expected answer, got \(once)") }
        XCTAssertFalse(service.webSearchConsentGranted())
    }

    func testSearchAndAnswerDisabledWhenWebOff() async throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        core.webConfig.enabled = false // web search is on by default; turn it off explicitly
        let service = SummonAIService(ladder: .testing(fake: FakeModelRung()), core: core)
        let outcome = try await service.searchAndAnswer(
            query: "x", provider: FakeAuthorizedWebSearchProvider()
        )
        XCTAssertEqual(outcome, .disabled)
    }

    func testFakeUnavailable() async throws {
        let ladder = AILadder.testing(fake: FakeModelRung(forcedAvailable: false))
        do {
            _ = try await ladder.complete(prompt: "x")
            XCTFail("expected throw")
        } catch let error as ModelRungError {
            guard case .unavailable = error else { XCTFail("\(error)"); return }
        }
    }

    func testEmptyPromptRejected() async {
        let ladder = AILadder.testing()
        do {
            _ = try await ladder.complete(prompt: "   ")
            XCTFail("expected empty")
        } catch let error as ModelRungError {
            XCTAssertEqual(error, .emptyPrompt)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testProductionLadderIncludesL1Slot() async {
        let container = temporaryModelsContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let rungs = AILadder.defaultProductionRungs(modelsContainer: container)
        let rows = await AILadder(rungs: rungs).status()
        XCTAssertTrue(rows.contains { $0.id == .l1Apple })
    }

    func testProductionLadderIncludesOnlyImplementedRungs() {
        let container = temporaryModelsContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let ids = AILadder.defaultProductionRungs(modelsContainer: container).map(\.id)
        XCTAssertTrue(ids.contains(.l1Apple))
        XCTAssertTrue(ids.contains(.l0Packaged))
        XCTAssertFalse(ids.contains(.l2LocalRuntime))
    }

    private func temporaryModelsContainer() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-ai-ladder-\(UUID().uuidString)", isDirectory: true)
    }
}
