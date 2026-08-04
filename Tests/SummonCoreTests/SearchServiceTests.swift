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

        AppCatalog.invalidateCache()
        let catalog = AppCatalog(searchPaths: [tmp], cacheTTL: 0)
        let hits = catalog.search(query: try FilterGrammar.parse("Fixture"), limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].title, "FixtureApp")
        XCTAssertEqual(hits[0].kind, .app)
    }

    /// Prefix must beat alphabetical noise; short contains must not bury Safari-like names.
    func testAppPrefixBeatsContainsNoise() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-apps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Many names that *contain* "sa" but only Safari *prefixes* "saf".
        for name in [
            "Messages", "WhatsApp", "osaurus", "Screen Sharing", "Screenshot",
            "Script Editor", "Safari", "Safe Exam Browser", "Sample App",
        ] {
            try FileManager.default.createDirectory(
                at: tmp.appendingPathComponent("\(name).app"),
                withIntermediateDirectories: true
            )
        }
        // Symlink app (macOS Safari shape).
        let real = tmp.appendingPathComponent("_real/SafariReal.app")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("SafariLink.app")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        AppCatalog.invalidateCache()
        let catalog = AppCatalog(searchPaths: [tmp], cacheTTL: 0)

        let s = catalog.search(query: try FilterGrammar.parse("s"), limit: 50)
        XCTAssertTrue(s.contains { $0.title == "Safari" }, "s → Safari; got \(s.map(\.title))")
        // 1-char: prefix only — Messages should not rank as S-prefix.
        XCTAssertFalse(s.contains { $0.title == "Messages" })

        let sa = catalog.search(query: try FilterGrammar.parse("sa"), limit: 20)
        XCTAssertEqual(sa.first?.title, "Safari", "sa → Safari first; got \(sa.map(\.title))")
        XCTAssertTrue(sa.contains { $0.title == "SafariLink" })

        let saf = catalog.search(query: try FilterGrammar.parse("saf"), limit: 10)
        XCTAssertTrue(saf.contains { $0.title.hasPrefix("Saf") }, "saf → Saf*; got \(saf.map(\.title))")
        XCTAssertFalse(saf.contains { $0.title == "Messages" })
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
        XCTAssertEqual(results.first?.title, "🚀")
        XCTAssertEqual(results.first?.subtitle, "rocket")
    }

    /// Free text: apps above emoji (emoji still present when it matches).
    func testFreeTextAppBeforeEmoji() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-apps-\(UUID().uuidString)", isDirectory: true)
        let app = tmp.appendingPathComponent("RocketMail.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let core = try SummonCore.inMemory(appSearchPaths: [tmp])
        let results = try core.search.search("rocket")
        let firstApp = results.firstIndex { $0.kind == .app }
        let firstEmoji = results.firstIndex { $0.kind == .emoji }
        XCTAssertNotNil(firstApp, "expected a matching app")
        XCTAssertNotNil(firstEmoji, "emoji should still match free text")
        XCTAssertLessThan(firstApp!, firstEmoji!)
        XCTAssertEqual(results[firstApp!].title, "RocketMail")
        XCTAssertEqual(results[firstEmoji!].title, "🚀")
    }

    func testFreeTextKindRankBands() {
        XCTAssertGreaterThan(FreeTextKindRank.band(for: .app), FreeTextKindRank.band(for: .emoji))
        XCTAssertGreaterThan(FreeTextKindRank.band(for: .emoji), FreeTextKindRank.band(for: .file))
    }

    func testSystemCommandSearch() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let results = try core.search.search("lock kind:command")
        XCTAssertTrue(results.contains { $0.id == "command:lock" })
    }

    func testSystemCommandOpenSettingsViaExecutor() throws {
        let exec = RecordingModuleExecutor()
        let core = try SummonCore.inMemory(appSearchPaths: [], executor: exec)
        let result = SearchResult(
            id: "command:prefs",
            title: "System Settings",
            kind: .command,
            path: "x-apple.systempreferences:",
            payload: ["url": .string("x-apple.systempreferences:")]
        )
        _ = try core.invoke(actionName: "command.run", result: result, actor: .user)
        XCTAssertEqual(exec.calls.last?.op, "open")
        XCTAssertEqual(exec.calls.last?.value, "x-apple.systempreferences:")
    }

    func testSearchLatencyBudgetInMemory() throws {
        // No mdfind; measure pure core ranking after warm-up.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-apps-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("Foo.app"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }
        let core = try SummonCore.inMemory(appSearchPaths: [tmp])
        _ = try core.search.search("rocket") // warm emoji index + app cache
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 {
            _ = try core.search.search("rocket")
            _ = try core.search.search("high five")
            _ = try core.search.search("pray")
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / 60
        // Target: low single-digit ms average after warm (no mdfind).
        XCTAssertLessThan(ms, 25, "avg ms/query \(ms)")
    }

    func testCalculatorIncompleteDoesNotThrow() {
        // Regression: "2 +" used to abort via NSExpression NSException.
        XCTAssertNil(Calculator.evaluate("2 +"))
        XCTAssertNil(Calculator.evaluate("2 + "))
        XCTAssertNil(Calculator.evaluate("("))
        XCTAssertEqual(Calculator.evaluate("2 + 2"), 4)
        XCTAssertEqual(Calculator.evaluate("10 / 4"), 2.5)
        XCTAssertEqual(Calculator.evaluate("(1+2)*3"), 9)
        XCTAssertNotNil(Calculator.result(for: "2+2"))
        XCTAssertNil(Calculator.result(for: "2 +"))
    }
}
