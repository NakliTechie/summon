import XCTest
@testable import SummonCore

final class PolishBatchGTests: XCTestCase {
    func testDevUtilsSilentOnEmptyQuery() {
        XCTAssertTrue(DevUtils.search(query: "").isEmpty)
        XCTAssertTrue(DevUtils.search(query: "   ").isEmpty)
        XCTAssertFalse(DevUtils.search(query: "uuid").isEmpty)
        XCTAssertFalse(DevUtils.search(query: "timestamp").isEmpty)
    }

    func testPlainTextStripsHTML() {
        let plain = PasteboardPrivacy.asPlainText("<b>Hi</b>&nbsp;there")
        XCTAssertEqual(plain, "Hi there")
    }

    func testSnippetExpansionExactKeyword() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .snippetUpsert(id: "s1", name: "sig", body: "Best", keyword: ";sig"),
            actor: .user
        )
        let hits = try core.search.search(";sig")
        XCTAssertTrue(hits.contains { $0.kind == .snippet && $0.title == "sig" })
    }

    func testPastePlainViaRouter() throws {
        let exec = RecordingModuleExecutor()
        let hit = SearchResult(
            id: "c1",
            title: "x",
            kind: .clipboard,
            score: 1,
            payload: ["text": .string("<i>Hello</i>")]
        )
        try ModuleRouter.perform(actionName: "clipboard.pastePlain", result: hit, executor: exec)
        XCTAssertEqual(exec.pasteboard, "Hello")
    }
}
