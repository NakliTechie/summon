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
        XCTAssertFalse(ids.contains(.l3BYOK))
    }

    private func temporaryModelsContainer() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-ai-ladder-\(UUID().uuidString)", isDirectory: true)
    }
}
