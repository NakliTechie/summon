import XCTest
@testable import SummonCore

final class IntegrityBatchETests: XCTestCase {
    func testReplayDoesNotDoubleJournal() throws {
        let original = try SummonCore.inMemory()
        _ = try original.dispatch(
            action: .settingsSet(key: "k", value: .string("v")),
            actor: .user
        )
        let applied = try original.journal.appliedEntries()
        XCTAssertEqual(applied.count, 1)

        let fresh = try SummonCore.inMemory()
        try fresh.replay(entries: applied)
        // Replay must not append to fresh journal
        XCTAssertEqual(try fresh.journal.allEntries().count, 0)
        XCTAssertEqual(try fresh.settings.get("k"), .string("v"))
        XCTAssertEqual(try original.exportJSON(), try fresh.exportJSON())
    }

    func testReplayAppliesAgentHistoricalActionsWithoutRestage() throws {
        let original = try SummonCore.inMemory()
        // Agent non-restricted setting applies
        _ = try original.dispatch(
            action: .settingsSet(key: "feature.x", value: .bool(true)),
            actor: .agent
        )
        // Agent destructive stages — not in appliedEntries
        _ = try original.dispatch(action: .clipboardClearUnpinned, actor: .agent)
        let applied = try original.journal.appliedEntries()
        XCTAssertEqual(applied.count, 1)

        let fresh = try SummonCore.inMemory()
        try fresh.replay(entries: applied)
        XCTAssertEqual(try fresh.settings.get("feature.x"), .bool(true))
        XCTAssertEqual(try fresh.journal.allEntries().count, 0)
    }

    func testImportVersionGate() throws {
        let core = try SummonCore.inMemory()
        let bad = Data(#"""
        {"version":99,"exportedAt":"2026-01-01T00:00:00Z",
         "snapshot":{"schemaVersion":3,"settings":{},"snippets":[],"clipboard":[],"quicklinks":[]},
         "aliases":[],"favorites":[],"includeClipboard":false}
        """#.utf8)
        XCTAssertThrowsError(try DataExport.importJSON(bad, into: core))
    }

    func testImportSettingsViaBus() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .settingsSet(key: "theme", value: .string("dark")),
            actor: .user
        )
        let data = try DataExport.export(core: core)
        let core2 = try SummonCore.inMemory()
        try DataExport.importJSON(data, into: core2)
        XCTAssertEqual(try core2.settings.get("theme"), .string("dark"))
        // Import journals settings writes
        XCTAssertFalse(try core2.journal.appliedEntries().isEmpty)
    }

    func testSearXNGRejectsNonLoopbackByDefault() async {
        var cfg = WebSearchConfig(enabled: true, baseURL: "http://example.com:8080")
        let client = SearXNGClient(config: cfg)
        do {
            _ = try await client.search(query: "x")
            XCTFail("expected invalid base URL")
        } catch let e as WebSearchError {
            XCTAssertEqual(e, .invalidBaseURL)
        } catch {
            XCTFail("\(error)")
        }
        cfg.allowNonLoopback = true
        // Still may fail network — just allow host check to pass by constructing allowed
        XCTAssertTrue(WebSearchConfig.isAllowedHost(
            URL(string: "http://example.com")!,
            allowNonLoopback: true
        ))
        XCTAssertTrue(WebSearchConfig.isAllowedHost(
            URL(string: "http://127.0.0.1:8080")!,
            allowNonLoopback: false
        ))
    }

    func testFTSPhraseQuoteSurvivesOperators() throws {
        let core = try SummonCore.inMemory()
        try core.grantFTSConsent()
        try core.setFTSEnabled(true)
        try core.fts.upsert(FTSDocument(id: "1", title: "doc", body: "hello world", path: nil))
        // Operator-like tokens must not throw (phrase-quoted MATCH)
        XCTAssertNoThrow(try core.fts.search(query: "hello AND OR NOT", limit: 10))
        let hits = try core.fts.search(query: "hello world", limit: 10)
        XCTAssertFalse(hits.isEmpty)
    }

    func testMDQueryEscape() {
        let e = MdfindSpotlightIndex.escapeMDQuery(#"foo*bar"baz\"#)
        XCTAssertFalse(e.contains("*"))
        XCTAssertFalse(e.contains("\""))
    }
}
