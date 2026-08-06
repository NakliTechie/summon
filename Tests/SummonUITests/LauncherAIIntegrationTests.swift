import XCTest
@testable import SummonCore
@testable import SummonUI

final class LauncherAIIntegrationTests: XCTestCase {
    func testAIMissOfferIsRoutableAndPreservesThePrompt() throws {
        let integration = integrationReturningStaged()
        XCTAssertNil(integration.offerResult(for: "two words"))
        XCTAssertNil(integration.offerResult(for: "ai:"))

        let offer = try XCTUnwrap(integration.offerResult(for: "arrange these windows evenly"))
        XCTAssertEqual(offer.payload["action"]?.stringValue, "ai.ask")
        XCTAssertEqual(offer.payload["prompt"]?.stringValue, "arrange these windows evenly")
        XCTAssertEqual(
            ObjectActionGrammar.actions(for: offer).map(\.name),
            ["ai.ask"]
        )
    }

    func testExplicitAIPrefixOffersForShortPrompt() throws {
        let integration = integrationReturningStaged()
        let offer = try XCTUnwrap(integration.offerResult(for: "ask: summarize"))
        XCTAssertEqual(offer.payload["prompt"]?.stringValue, "summarize")
    }

    func testRespondDelegatesAndReturnsVisibleRungAndEgress() async throws {
        let integration = integrationReturningStaged()
        let response = try await integration.respond(prompt: "draft a reply")
        guard case let .staged(proposalID, rung, egress) = response else {
            return XCTFail("expected staged response, got \(response)")
        }
        XCTAssertEqual(proposalID, "proposal-1")
        XCTAssertEqual(rung, "L0")
        XCTAssertEqual(egress, "")
    }

    func testAnswerResponseShowsReadOnlyAnswerAndNeverStages() throws {
        let integration = LauncherAIIntegration { _ in
            .answer(text: "Paris is the capital of France.", rung: "L1", egressSummary: "")
        }
        let panel = LauncherPanelController(
            core: try SummonCore.inMemory(),
            aiIntegration: integration
        )
        panel.runAI(LauncherConfirmation(
            actionName: "ai.ask",
            result: SearchResult(
                id: "ai:fixture",
                title: "Ask local AI",
                kind: .command,
                payload: ["prompt": .string("what is the capital of france")]
            ),
            query: "what is the capital of france",
            requiresUserConfirmation: false
        ))

        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertFalse(panel.aiAnswerView.isHidden)
        XCTAssertEqual(panel.aiAnswerView.answer, "Paris is the capital of France.")
        // The answer shape must never wear the staged Accept/Reject chrome.
        XCTAssertTrue(panel.stagedReviewView.isHidden)
    }

    func testPanelAcceptsOptionalAICompositionWithoutChangingNoAIBuilds() throws {
        let panel = LauncherPanelController(
            core: try SummonCore.inMemory(),
            aiIntegration: integrationReturningStaged()
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
            title: "Ask local AI",
            kind: .command,
            payload: ["prompt": .string("fixture prompt")]
        )
        panel.runAI(LauncherConfirmation(
            actionName: "ai.ask",
            result: result,
            query: "fixture prompt",
            requiresUserConfirmation: false
        ))

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(panel.footerError, L10n.t(.degradedAI))
        XCTAssertFalse(panel.footerError?.contains("raw provider failure") == true)
    }

    private func integrationReturningStaged() -> LauncherAIIntegration {
        LauncherAIIntegration { _ in
            .staged(proposalID: "proposal-1", rung: "L0", egressSummary: "")
        }
    }
}
