import XCTest
@testable import SummonCore

final class PhaseAStoresTests: XCTestCase {
    func testRootAliasExpand() {
        XCTAssertEqual(RootAlias.expandQuery("clip invoice"), "kind:clipboard invoice")
        XCTAssertEqual(RootAlias.expandQuery("snip"), "kind:snippet")
        XCTAssertEqual(RootAlias.expandQuery("hello"), "hello")
    }

    func testFrecencyBoostRanksHigher() throws {
        let core = try SummonCore.inMemory()
        try core.frecency.record(resultID: "a", title: "Alpha", kind: "app")
        try core.frecency.record(resultID: "a", title: "Alpha", kind: "app")
        let boost = try core.frecency.boost(for: "a")
        XCTAssertGreaterThan(boost, 0)
        let zero = try core.frecency.boost(for: "missing")
        XCTAssertEqual(zero, 0)
    }

    func testSearchAppliesRootAliasClipboard() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "c1",
                text: "secret-token-xyz",
                sourceApp: "Test",
                createdAt: Date(),
                pinned: false
            ),
            actor: .user
        )
        let hits = try core.search.search("clip secret-token")
        XCTAssertTrue(hits.contains { $0.kind == .clipboard })
    }

    func testLatencyProbeP95() throws {
        let sample = try LatencyProbe.measure(label: "noop", iterations: 20) {}
        XCTAssertEqual(sample.iterations, 20)
        XCTAssertLessThan(sample.milliseconds, 50)
    }

    func testGuideResults() {
        let r = GuideContent.searchResults()
        XCTAssertFalse(r.isEmpty)
        XCTAssertTrue(r[0].id.hasPrefix("guide:"))
        XCTAssertEqual(r[0].payload["action"], .string("snippet.copy"))
        XCTAssertTrue(r.contains { $0.title == ShortcutCatalog.clipboardHistory })
        XCTAssertTrue(r.contains { $0.subtitle?.contains("summon-cli snippet add") == true })
        XCTAssertTrue(r.contains { $0.subtitle?.contains("summon-cli quicklink add") == true })
        XCTAssertTrue(r.contains { $0.title == "Add favorite" })
    }

    func testSessionRecordsFrecencyOnConfirm() throws {
        let core = try SummonCore.inMemory(
            appSearchPaths: [URL(fileURLWithPath: "/Applications")]
        )
        let session = LauncherSession(core: core)
        // seed a clipboard item and select it
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "clip1",
                text: "hello-world-frecency",
                sourceApp: nil,
                createdAt: Date(),
                pinned: false
            ),
            actor: .user
        )
        _ = try session.setQuery("clip hello-world")
        XCTAssertFalse(session.results.isEmpty)
        let selectedID = session.selected?.id
        _ = try session.confirm(actor: .user)
        let recents = try core.frecency.recents(limit: 5)
        XCTAssertFalse(recents.isEmpty, "confirm should record frecency")
        if let selectedID {
            XCTAssertGreaterThan(try core.frecency.boost(for: selectedID), 0)
        }
        XCTAssertEqual(recents.first?.payload["text"], .string("hello-world-frecency"))
    }

    func testFTSSearchWhenEnabled() throws {
        let core = try SummonCore.inMemory()
        try core.grantFTSConsent()
        try core.setFTSEnabled(true)
        try core.fts.upsert(FTSDocument(id: "d1", title: "Report", body: "quarterly revenue figures", path: "/tmp/r.txt"))
        let hits = try core.search.search("revenue")
        XCTAssertTrue(hits.contains { $0.id.hasPrefix("fts:") })
    }

    func testClipboardIgnore() throws {
        let core = try SummonCore.inMemory()
        try core.clipboardIgnore.add("1Password")
        try core.clipboardIgnore.add("com.example.SecretApp")
        XCTAssertTrue(try core.clipboardIgnore.isIgnored("1Password"))
        let r = try core.ingestClipboard(text: "secret", types: ["public.utf8-plain-text"], sourceApp: "1Password")
        XCTAssertNil(r)
        let bundleIgnored = try core.ingestClipboard(
            text: "bundle-secret",
            types: ["public.utf8-plain-text"],
            sourceApp: "Renamed App",
            sourceBundleID: "COM.EXAMPLE.SECRETAPP"
        )
        XCTAssertNil(bundleIgnored)

        let spoofedSource = try core.ingestClipboard(
            text: "spoofed source",
            types: ["public.utf8-plain-text"],
            sourceApp: "Allowed App",
            sourceBundleID: "com.example.allowed",
            observedSourceApp: "1Password",
            observedSourceBundleID: "com.agilebits.onepassword"
        )
        XCTAssertNil(spoofedSource)
    }

    func testFavoritesAndHistory() throws {
        let core = try SummonCore.inMemory()
        try core.favorites.add(FavoriteItem(resultID: "app:X", title: "X", kind: "app"))
        try core.history.record("calc 2+2")
        XCTAssertEqual(try core.favorites.all().count, 1)
        XCTAssertEqual(try core.history.recent(limit: 5).first?.query, "calc 2+2")
    }

    func testAliasStore() throws {
        let core = try SummonCore.inMemory()
        try core.aliases.set(LearnedAlias(
            keyword: "sl",
            targetResultID: "quicklink:slack",
            title: "Slack",
            kind: "quicklink",
            path: "https://app.slack.com",
            payload: ["url": .string("https://app.slack.com")]
        ))
        let session = LauncherSession(core: core)
        _ = try session.setQuery("sl")
        XCTAssertEqual(session.results.first?.title, "Slack")
        XCTAssertEqual(session.results.first?.path, "https://app.slack.com")
        XCTAssertEqual(session.results.first?.payload["url"], .string("https://app.slack.com"))
    }
}
