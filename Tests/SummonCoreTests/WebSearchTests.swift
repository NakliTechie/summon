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

    func testSearXNGDiscoveryReadsLoopbackURLOnly() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("searxng-\(UUID().uuidString).url")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Whatever free port up.sh chose, the app reads it back.
        try "http://127.0.0.1:8391/\n".write(to: tmp, atomically: true, encoding: .utf8)
        XCTAssertEqual(SearXNGDiscovery.discoveredBaseURL(file: tmp), "http://127.0.0.1:8391/")

        // Non-loopback is rejected (SSRF guard).
        try "http://evil.example.com/\n".write(to: tmp, atomically: true, encoding: .utf8)
        XCTAssertNil(SearXNGDiscovery.discoveredBaseURL(file: tmp))

        // Missing file → nil (no SearXNG running).
        try FileManager.default.removeItem(at: tmp)
        XCTAssertNil(SearXNGDiscovery.discoveredBaseURL(file: tmp))
    }

    func testSearchQueryStripsConversationalPrefixes() {
        XCTAssertEqual(WebEnrich.searchQuery(from: "quick, what is quantum computing"),
                       "what is quantum computing")
        XCTAssertEqual(WebEnrich.searchQuery(from: "tell me about the internet"), "the internet")
        XCTAssertEqual(WebEnrich.searchQuery(from: "what do you know about who wrote hamlet"),
                       "who wrote hamlet")
        XCTAssertEqual(WebEnrich.searchQuery(from: "so, please explain gravity"), "gravity")
        // A bare query is unchanged; an all-filler string falls back to the original.
        XCTAssertEqual(WebEnrich.searchQuery(from: "capital of france"), "capital of france")
    }

    func testWikipediaParseMapsPagesToHitsAndStripsMarkup() {
        let json = """
        {"pages":[
          {"key":"Canberra","title":"Canberra","description":"Capital city of Australia",
           "excerpt":"<span class=\\"searchmatch\\">Canberra</span> is the capital of Australia"},
          {"key":"Swift_(programming_language)","title":"Swift (programming language)",
           "description":"Apple's language","excerpt":"a &amp; b"}
        ]}
        """
        let hits = WikipediaSearchClient.parse(Data(json.utf8), host: "en.wikipedia.org", limit: 5)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].title, "Canberra")
        XCTAssertEqual(hits[0].url, "https://en.wikipedia.org/wiki/Canberra")
        XCTAssertTrue(hits[0].snippet.contains("Capital city of Australia"))
        XCTAssertFalse(hits[0].snippet.contains("<span"))  // markup stripped
        XCTAssertEqual(hits[1].url, "https://en.wikipedia.org/wiki/Swift_(programming_language)")
        XCTAssertTrue(hits[1].snippet.contains("a & b"))    // entity decoded
    }

    func testWikipediaSearchRequiresEgressAuthorization() async {
        let client = WikipediaSearchClient()
        do {
            _ = try await client.search(query: "swift", authorization: nil)
            XCTFail("expected egress authorization failure")
        } catch let error as WebSearchError {
            if case .network = error { /* expected */ } else { XCTFail("\(error)") }
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
