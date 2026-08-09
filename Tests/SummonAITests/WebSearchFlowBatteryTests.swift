import XCTest
@testable import SummonAI
import SummonCore

/// Battery for the web-search → answer flow: every decision point that governs
/// whether "Search the web & answer" actually produces a result. Built after a
/// dead-end where search fetched results, then threw because no model was
/// available. Deterministic and fast — no network, no real model.
final class WebSearchFlowBatteryTests: XCTestCase {
    /// A service whose ladder either has a model (`model`) or none (nil → complete
    /// throws, mimicking a Mac without Apple Intelligence).
    private func makeService(model: FakeModelRung?, webEnabled: Bool) throws -> SummonAIService {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        core.webConfig.enabled = webEnabled
        let ladder = model.map { AILadder(rungs: [$0]) } ?? AILadder(rungs: [])
        return SummonAIService(ladder: ladder, core: core)
    }

    private func provider(hits count: Int) -> FakeAuthorizedWebSearchProvider {
        FakeAuthorizedWebSearchProvider(
            host: "example.com",
            hits: (0..<count).map {
                WebHit(title: "Result \($0)", url: "https://example.com/\($0)", snippet: "snippet \($0)")
            }
        )
    }

    // MARK: - Outcome matrix

    func testWebOffIsDisabled() async throws {
        let service = try makeService(model: FakeModelRung(), webEnabled: false)
        let outcome = try await service.searchAndAnswer(query: "q", provider: provider(hits: 2))
        XCTAssertEqual(outcome, .disabled)
    }

    func testNoConsentAsksThenAllowOnceProceeds() async throws {
        let service = try makeService(model: FakeModelRung(cannedText: "A"), webEnabled: true)
        let asked = try await service.searchAndAnswer(query: "q", provider: provider(hits: 1))
        XCTAssertEqual(asked, .needsConsent(host: "example.com"))

        let once = try await service.searchAndAnswer(query: "q", provider: provider(hits: 1), allowOnce: true)
        guard case .answer = once else { return XCTFail("allow-once should proceed, got \(once)") }
        XCTAssertFalse(service.webSearchConsentGranted(), "allow-once must not persist consent")
    }

    func testStickyConsentProceedsWithoutAllowOnce() async throws {
        let service = try makeService(model: FakeModelRung(cannedText: "A"), webEnabled: true)
        try service.grantWebSearchConsentAlways()
        let outcome = try await service.searchAndAnswer(query: "q", provider: provider(hits: 1))
        guard case .answer = outcome else { return XCTFail("sticky consent should proceed, got \(outcome)") }
    }

    func testEmptyHitsIsNoResults() async throws {
        let service = try makeService(model: FakeModelRung(), webEnabled: true)
        try service.grantWebSearchConsentAlways()
        let outcome = try await service.searchAndAnswer(query: "q", provider: provider(hits: 0))
        XCTAssertEqual(outcome, .noResults)
    }

    func testHitsWithModelSynthesizeAnswer() async throws {
        let service = try makeService(model: FakeModelRung(cannedText: "SYNTHESIZED"), webEnabled: true)
        try service.grantWebSearchConsentAlways()
        let outcome = try await service.searchAndAnswer(query: "q", provider: provider(hits: 2))
        guard case let .answer(text, _, sources) = outcome else { return XCTFail("expected answer, got \(outcome)") }
        XCTAssertTrue(text.contains("SYNTHESIZED"))
        XCTAssertEqual(sources.count, 2)
    }

    func testHitsWithoutModelReturnResults() async throws {
        // The dead-end this battery exists for: no model must NOT throw away results.
        let service = try makeService(model: nil, webEnabled: true)
        try service.grantWebSearchConsentAlways()
        let outcome = try await service.searchAndAnswer(query: "q", provider: provider(hits: 3))
        guard case let .answer(text, _, sources) = outcome else {
            return XCTFail("no model must still return the fetched results, got \(outcome)")
        }
        XCTAssertEqual(sources.count, 3, "the fetched results are returned")
        XCTAssertFalse(text.isEmpty)
    }
}
