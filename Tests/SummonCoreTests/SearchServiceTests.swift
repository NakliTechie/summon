import XCTest
@testable import SummonCore

final class SearchServiceTests: XCTestCase {
    func testCalculatorInline() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let results = try core.search.search("2 + 2")
        XCTAssertEqual(results.first?.kind, .calculation)
        XCTAssertEqual(results.first?.title, "4")
    }

    func testCalculatorPower() {
        XCTAssertEqual(Calculator.evaluate("2^10"), 1024)
        XCTAssertEqual(Calculator.format(1024), "1024")
    }

    func testFakeSpotlightFilters() throws {
        let now = Date().timeIntervalSince1970
        let files = [
            SearchResult(
                id: "f1",
                title: "Invoice.pdf",
                kind: .file,
                path: "/tmp/Invoice.pdf",
                score: 10,
                payload: ["mtime": .number(now)]
            ),
            SearchResult(
                id: "f2",
                title: "Old.pdf",
                kind: .file,
                path: "/tmp/Old.pdf",
                score: 5,
                payload: ["mtime": .number(now - 86400 * 40)]
            ),
            SearchResult(
                id: "f3",
                title: "Notes.txt",
                kind: .file,
                path: "/tmp/Notes.txt",
                score: 1,
                payload: ["mtime": .number(now)]
            ),
        ]
        let core = try SummonCore.inMemory(
            spotlight: FakeSpotlightIndex(files: files),
            appSearchPaths: []
        )
        let results = try core.search.search("kind:pdf modified:<7d")
        let titles = results.map(\.title)
        XCTAssertTrue(titles.contains("Invoice.pdf"))
        XCTAssertFalse(titles.contains("Old.pdf"))
        XCTAssertFalse(titles.contains("Notes.txt"))
    }

    func testSnippetSearchAndReplay() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let id = "snip-1"
        _ = try core.dispatch(
            action: .snippetUpsert(id: id, name: "sig", body: "Best regards", keyword: "sig"),
            actor: .user
        )
        let results = try core.search.search("sig kind:snippet")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].kind, .snippet)

        let copy = try core.replayedCopy()
        XCTAssertEqual(try core.exportJSON(), try copy.exportJSON())
        XCTAssertEqual(try copy.snippets.get(id: id)?.body, "Best regards")
    }

    func testAppCatalogFromFixtureDir() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-apps-\(UUID().uuidString)", isDirectory: true)
        let app = tmp.appendingPathComponent("FixtureApp.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let catalog = AppCatalog(searchPaths: [tmp])
        let hits = catalog.search(query: try FilterGrammar.parse("Fixture"), limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].title, "FixtureApp")
        XCTAssertEqual(hits[0].kind, .app)
    }

    func testObjectActionGrammar() {
        let app = SearchResult(id: "a", title: "X", kind: .app)
        let actions = ObjectActionGrammar.actions(for: app)
        XCTAssertTrue(actions.contains { $0.name == "app.open" })

        let snip = SearchResult(id: "s", title: "Y", kind: .snippet)
        let snipActions = ObjectActionGrammar.actions(for: snip)
        XCTAssertTrue(snipActions.contains { $0.isDestructive && $0.name == "snippet.delete" })
    }

    func testEmojiSearch() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let results = try core.search.search("rocket kind:emoji")
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.kind, .emoji)
        XCTAssertTrue(results.first?.title.contains("🚀") == true)
    }
}
