import XCTest
@testable import SummonCore

final class PhaseBGModulesTests: XCTestCase {
    func testUnitConversion() {
        let r = UnitConversion.convert("10 km to mi")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.kind, .calculation)
    }

    func testColorPicker() {
        let r = ColorPickerUtil.parse("#ff00aa")
        XCTAssertEqual(r?.title, "#FF00AA")
        XCTAssertEqual(r?.payload["action"], .string("snippet.copy"))
    }

    func testDevUUID() {
        let hits = DevUtils.search(query: "uuid")
        XCTAssertFalse(hits.isEmpty)
    }

    func testDevBase64PreservesPayloadCaseAndDerivesTheCommandBoundary() {
        XCTAssertEqual(
            DevUtils.search(query: "base64 MixedCase").first?.title,
            Data("MixedCase".utf8).base64EncodedString()
        )
        XCTAssertEqual(
            DevUtils.search(query: "DeCoDe TWl4ZWRDYXNl").first?.title,
            "MixedCase"
        )
    }

    func testDestructiveGuardAgentBlocked() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "x",
                text: "t",
                sourceApp: nil,
                createdAt: Date(),
                pinned: false
            ),
            actor: .user
        )
        let r = try core.dispatch(action: .clipboardDelete(id: "x"), actor: .agent)
        XCTAssertFalse(r.isApplied)
        XCTAssertTrue(r.isStaged)
        // user may delete
        let r2 = try core.dispatch(action: .clipboardDelete(id: "x"), actor: .user)
        XCTAssertTrue(r2.isApplied)
    }

    func testDataExportRoundTrip() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .snippetUpsert(id: "s1", name: "hi", body: "hello", keyword: "h"),
            actor: .user
        )
        try core.aliases.set(LearnedAlias(keyword: "x", targetResultID: "a", title: "A", kind: "app"))
        let data = try DataExport.export(core: core)
        let core2 = try SummonCore.inMemory()
        try DataExport.importJSON(data, into: core2)
        XCTAssertEqual(try core2.snippets.all().count, 1)
        XCTAssertEqual(try core2.aliases.all().count, 1)
    }

    func testPowerModuleSearchRoots() throws {
        let core = try SummonCore.inMemory()
        XCTAssertFalse(try core.search.search("screenshot").isEmpty)
        XCTAssertFalse(try core.search.search("settings").isEmpty)
        XCTAssertFalse(try core.search.search("welcome").contains { $0.id.hasPrefix("onboard:") })
        XCTAssertFalse(try core.search.search("define foobar").isEmpty)
        let memory = try core.search.search("mem").first { $0.id == "widget:mem" }
        XCTAssertEqual(memory?.payload["action"], .string("snippet.copy"))
        XCTAssertFalse(try core.search.search("tabs").contains { $0.id.hasPrefix("browser:") })
        XCTAssertFalse(try core.search.search("contact Ada").contains { $0.id.hasPrefix("contact:") })
        XCTAssertFalse(try core.search.search("camera").contains { $0.id.hasPrefix("camera:") })
        XCTAssertFalse(try core.search.search("autoquit Mail").contains { $0.id == "autoquit" })
    }

    func testVisiblePowerRowsDescribeTheirCurrentEffects() throws {
        let core = try SummonCore.inMemory()

        let shots = try core.search.search("screenshot")
        XCTAssertEqual(shots.first { $0.id == "shot:region" }?.subtitle, "select a region · copy to clipboard")
        XCTAssertEqual(shots.first { $0.id == "shot:full" }?.subtitle, "copy display screenshot to clipboard")

        let terminal = try core.search.search("> echo hello").first { $0.id.hasPrefix("term:") }
        XCTAssertEqual(terminal?.title, "Open Terminal with command copied")
        XCTAssertTrue(terminal?.subtitle?.contains("Summon never executes it") == true)
        XCTAssertEqual(terminal?.payload["action"], .string("terminal.run"))
    }

    func testSnippetExpansionMatch() {
        let snips = [Snippet(id: "1", name: "sig", body: "Best", keyword: ";sig")]
        XCTAssertNotNil(SnippetExpansion.match(typed: "hello;sig", snippets: snips))
        XCTAssertNil(SnippetExpansion.match(typed: "hello", snippets: snips))
    }

    func testSemanticS3Rank() {
        let ranked = SemanticSearchLocal.rank(
            query: "invoice payment",
            documents: [
                (id: "1", text: "cat photos"),
                (id: "2", text: "invoice payment due"),
            ]
        )
        XCTAssertEqual(ranked.first?.id, "2")
    }

    func testCalendarFake() throws {
        let cal = CalendarSurface(enumerator: FakeCalendarEnumerator(events: [
            CalendarEventDescriptor(title: "Standup", start: Date(), end: Date().addingTimeInterval(1800)),
        ]))
        let hits = try cal.search(query: "cal stand")
        XCTAssertEqual(hits.count, 1)
    }

    func testEmojiCatalogExpanded() {
        let cat = EmojiCatalog()
        XCTAssertGreaterThanOrEqual(cat.entries.count, 1000)
    }

    func testEmojiAmbiguityHighFiveAndPray() {
        let cat = EmojiCatalog()
        let highFive = cat.search(query: FilterQuery(freeText: "high five", filters: []), limit: 20)
        let glyphs = Set(highFive.map(\.title))
        // Ambiguity: raising hands, folded hands (common misuse), raised hand
        XCTAssertTrue(glyphs.contains("🙌") || glyphs.contains("🙏") || glyphs.contains("✋"),
                      "high five should hit hand emoji; got \(glyphs)")
        let pray = cat.search(query: FilterQuery(freeText: "pray", filters: []), limit: 10)
        XCTAssertTrue(pray.contains { $0.title == "🙏" }, "pray → folded hands")
        let thanks = cat.search(query: FilterQuery(freeText: "thank you", filters: []), limit: 10)
        XCTAssertTrue(thanks.contains { $0.title == "🙏" }, "thank you → folded hands")
    }

    func testSettingsCatalog() {
        let hits = SettingsCatalog.search(query: "settings socket")
        XCTAssertFalse(hits.isEmpty)
    }

}

/// S3 lives in SummonAI; keep a local test double in Core tests for bag-of-words.
enum SemanticSearchLocal {
    static func embed(_ text: String) -> [Double] {
        var v = [Double](repeating: 0, count: 32)
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        for t in tokens {
            var h = 0
            for u in t.unicodeScalars { h = (h &* 31 &+ Int(u.value)) & 0x7fffffff }
            v[h % 32] += 1
        }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { v = v.map { $0 / norm } }
        return v
    }

    static func rank(query: String, documents: [(id: String, text: String)]) -> [(id: String, score: Double)] {
        let qe = embed(query)
        return documents
            .map { id, text -> (String, Double) in
                let de = embed(text)
                let score = zip(qe, de).reduce(0.0) { $0 + $1.0 * $1.1 }
                return (id, score)
            }
            .sorted { $0.1 > $1.1 }
    }
}
