import XCTest
@testable import SummonCore

final class ClipboardPrivacyTests: XCTestCase {
    func testConcealedTypeSkipped() {
        XCTAssertTrue(
            PasteboardPrivacy.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        )
        XCTAssertFalse(
            PasteboardPrivacy.isStorableText(
                types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
                hasString: true
            )
        )
    }

    func testTransientSkipped() {
        XCTAssertTrue(PasteboardPrivacy.shouldSkip(types: ["org.nspasteboard.TransientType"]))
        XCTAssertTrue(PasteboardPrivacy.shouldSkip(types: ["de.petermaurer.TransientPasteboardType"]))
    }

    func testPlainTextAllowed() {
        XCTAssertFalse(PasteboardPrivacy.shouldSkip(types: ["public.utf8-plain-text"]))
        XCTAssertTrue(
            PasteboardPrivacy.isStorableText(types: ["public.utf8-plain-text"], hasString: true)
        )
    }

    func testIngestAndSearch() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let allowed = try core.ingestClipboard(
            text: "invoice-42",
            types: ["public.utf8-plain-text"],
            sourceApp: "Test"
        )
        XCTAssertNotNil(allowed)
        let skipped = try core.ingestClipboard(
            text: "secret-password",
            types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]
        )
        XCTAssertNil(skipped)

        let results = try core.search.search("invoice kind:clipboard")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].kind, .clipboard)

        let copy = try core.replayedCopy()
        XCTAssertEqual(try core.exportJSON(), try copy.exportJSON())
    }

    func testModuleOpenViaRecordingExecutor() throws {
        let exec = RecordingModuleExecutor()
        let core = try SummonCore.inMemory(appSearchPaths: [], executor: exec)
        let result = SearchResult(
            id: "app:/Applications/Test.app",
            title: "Test",
            kind: .app,
            path: "/Applications/Test.app"
        )
        _ = try core.invoke(actionName: "app.open", result: result, actor: .user)
        XCTAssertEqual(exec.calls.last?.op, "open")
        XCTAssertEqual(exec.calls.last?.value, "/Applications/Test.app")
    }

    func testLauncherSessionObjectMode() throws {
        let exec = RecordingModuleExecutor()
        let core = try SummonCore.inMemory(appSearchPaths: [], executor: exec)
        _ = try core.dispatch(
            action: .quicklinkUpsert(id: "q1", name: "Docs", url: "https://example.com", keyword: "docs"),
            actor: .user
        )
        let session = LauncherSession(core: core)
        _ = try session.setQuery("Docs kind:quicklink")
        XCTAssertEqual(session.results.count, 1)
        session.enterObjectMode()
        XCTAssertTrue(session.objectMode)
        XCTAssertTrue(session.objectActions.contains { $0.name == "quicklink.open" })
        let name = try session.confirm(actor: .user)
        XCTAssertEqual(name, "quicklink.open")
        XCTAssertEqual(exec.calls.last?.op, "open")
    }
}
