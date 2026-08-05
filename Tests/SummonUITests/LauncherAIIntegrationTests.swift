import XCTest
@testable import SummonCore
@testable import SummonUI

final class LauncherAIIntegrationTests: XCTestCase {
    func testAIMissOfferIsRoutableAndPreservesThePrompt() throws {
        let integration = integrationReturningFixture()
        XCTAssertNil(integration.offerResult(for: "two words"))
        XCTAssertNil(integration.offerResult(for: "ai:"))

        let offer = try XCTUnwrap(integration.offerResult(for: "arrange these windows evenly"))
        XCTAssertEqual(offer.payload["action"]?.stringValue, "ai.stage")
        XCTAssertEqual(offer.payload["prompt"]?.stringValue, "arrange these windows evenly")
        XCTAssertEqual(
            ObjectActionGrammar.actions(for: offer).map(\.name),
            ["ai.stage"]
        )
    }

    func testExplicitAIPrefixOffersForShortPrompt() throws {
        let integration = integrationReturningFixture()
        let offer = try XCTUnwrap(integration.offerResult(for: "ask: summarize"))
        XCTAssertEqual(offer.payload["prompt"]?.stringValue, "summarize")
    }

    func testStageDelegatesAndReturnsVisibleRungAndEgress() async throws {
        let integration = integrationReturningFixture()
        let outcome = try await integration.stage(prompt: "draft a reply")
        XCTAssertEqual(outcome.proposalID, "proposal-1")
        XCTAssertEqual(outcome.rung, "L0")
        XCTAssertEqual(outcome.egressSummary, "")
    }

    func testPanelAcceptsOptionalAICompositionWithoutChangingNoAIBuilds() throws {
        let panel = LauncherPanelController(
            core: try SummonCore.inMemory(),
            aiIntegration: integrationReturningFixture()
        )
        XCTAssertNotNil(panel.aiIntegration)
    }

    func testUnavailableAIUsesDesignedDegradedCopy() throws {
        let integration = LauncherAIIntegration { _ in
            throw CoreError.io("raw provider failure")
        }
        let panel = LauncherPanelController(
            core: try SummonCore.inMemory(),
            aiIntegration: integration
        )
        let result = SearchResult(
            id: "ai:fixture",
            title: "Stage with local AI",
            kind: .command,
            payload: ["prompt": .string("fixture prompt")]
        )
        panel.stageAI(LauncherConfirmation(
            actionName: "ai.stage",
            result: result,
            query: "fixture prompt",
            requiresUserConfirmation: false
        ))

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(panel.footerError, L10n.t(.degradedAI))
        XCTAssertFalse(panel.footerError?.contains("raw provider failure") == true)
    }

    private func integrationReturningFixture() -> LauncherAIIntegration {
        LauncherAIIntegration { _ in
            LauncherAIStageOutcome(
                proposalID: "proposal-1",
                rung: "L0",
                egressSummary: ""
            )
        }
    }
}
