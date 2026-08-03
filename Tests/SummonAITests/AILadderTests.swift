import XCTest
@testable import SummonAI
import SummonCore

final class AILadderTests: XCTestCase {
    func testFakeRungCompleteAndStage() async throws {
        let ladder = AILadder.testing(fake: FakeModelRung(cannedText: "unit"))
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let service = SummonAIService(ladder: ladder, core: core)
        let proposal = try await service.completeAndStage(prompt: "hello world", actor: .user)
        XCTAssertEqual(proposal.state, .staged)
        XCTAssertEqual(proposal.rung, .fake)
        XCTAssertTrue(proposal.output.contains("unit"))
        XCTAssertEqual(service.staging.allStaged().count, 1)
        XCTAssertEqual(service.staging.accept(proposal.id)?.state, .accepted)
        XCTAssertEqual(service.staging.allStaged().count, 0)
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
        let rows = await AILadder().status()
        XCTAssertTrue(rows.contains { $0.id == .l1Apple })
    }
}
