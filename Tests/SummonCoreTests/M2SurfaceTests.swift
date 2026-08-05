import XCTest
@testable import SummonCore

final class M2SurfaceTests: XCTestCase {
    func testWindowLeftHalf() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let f = WindowGeometry.frame(layout: .leftHalf, screen: screen, gap: 0)
        XCTAssertEqual(f.width, 500)
        XCTAssertEqual(f.height, 800)
        XCTAssertEqual(f.minX, 0)
    }

    func testWindowThirdsSum() {
        let screen = CGRect(x: 0, y: 0, width: 900, height: 600)
        let gap: CGFloat = 0
        let a = WindowGeometry.frame(layout: .leftThird, screen: screen, gap: gap)
        let b = WindowGeometry.frame(layout: .centerThird, screen: screen, gap: gap)
        let c = WindowGeometry.frame(layout: .rightThird, screen: screen, gap: gap)
        XCTAssertEqual(a.width + b.width + c.width, 900, accuracy: 0.1)
    }

    func testFTSIndexRoundTrip() throws {
        let db = try SummonDatabase.openInMemory()
        let fts = FTSIndex(dbQueue: db)
        try fts.migrate()
        try fts.upsert(FTSDocument(
            id: "1",
            title: "Quarterly invoice",
            body: "Payment due for ACME corp invoice 42",
            path: "/tmp/invoice.pdf"
        ))
        try fts.upsert(FTSDocument(
            id: "2",
            title: "Recipe",
            body: "Tomato pasta garlic",
            path: "/tmp/recipe.txt"
        ))
        XCTAssertEqual(try fts.count(), 2)
        let hits = try fts.search(query: "invoice")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].id, "1")
    }

    func testAppIntentsSearch() throws {
        let surface = AppIntentsSurface(enumerator: FakeAppIntentEnumerator())
        let hits = try surface.search(query: "mail")
        XCTAssertTrue(hits.contains { $0.title.contains("Email") })
    }

    func testProductionSearchDoesNotExposeFixtureAppIntents() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let hits = try core.search.search("action mail")

        XCTAssertFalse(hits.contains { $0.id.hasPrefix("intent:") })
    }

    func testL10nKeys() {
        let s = L10n.t(.degradedAI)
        XCTAssertFalse(s.isEmpty)
        XCTAssertTrue(s.contains("search"))
    }

    func testFTSConsentDefaultOff() {
        XCTAssertFalse(FTSConsent.default.granted)
    }
}
