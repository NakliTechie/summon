import XCTest
@testable import SummonCore

final class WebSearchTests: XCTestCase {
    func testEnablePresetsLocalhost() {
        var c = WebSearchConfig.default
        XCTAssertFalse(c.enabled)
        XCTAssertTrue(c.baseURL.isEmpty)
        c.enableWithLocalhostPreset()
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.baseURL, WebSearchConfig.localhostPreset)
    }

    func testFakeProvider() async throws {
        let p = FakeWebSearchProvider()
        let hits = try await p.search(query: "x", limit: 5)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].url.contains("example"))
    }

    func testEnrichPromptIncludesSources() {
        let hits = [WebHit(title: "A", url: "https://a.test", snippet: "snip")]
        let p = WebEnrich.enrichPrompt(question: "What is A?", hits: hits)
        XCTAssertTrue(p.contains("What is A?"))
        XCTAssertTrue(p.contains("https://a.test"))
    }

    func testDisabledThrows() async {
        let client = SearXNGClient(config: .default)
        do {
            _ = try await client.search(query: "x")
            XCTFail("expected disabled")
        } catch let e as WebSearchError {
            XCTAssertEqual(e, .disabled)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testStagedProposalStore() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        try core.staged.migrate()
        let p = PersistedStagedProposal(rung: "L1", prompt: "hi", output: "there")
        try core.staged.upsert(p)
        XCTAssertEqual(try core.staged.list().count, 1)
        try core.staged.setState(id: p.id, state: "accepted")
        XCTAssertEqual(try core.staged.list(state: "staged").count, 0)
        XCTAssertEqual(try core.staged.get(p.id)?.state, "accepted")
    }
}
