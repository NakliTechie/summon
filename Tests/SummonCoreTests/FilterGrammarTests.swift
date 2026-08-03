import XCTest
@testable import SummonCore

/// C1 gate: filter-grammar fixture parse tests.
final class FilterGrammarTests: XCTestCase {
    func testFreeTextOnly() throws {
        let q = try FilterGrammar.parse("quarterly invoice")
        XCTAssertEqual(q.freeText, "quarterly invoice")
        XCTAssertTrue(q.filters.isEmpty)
    }

    func testKindAndModified() throws {
        let q = try FilterGrammar.parse("invoice kind:pdf modified:<7d")
        XCTAssertEqual(q.freeText, "invoice")
        XCTAssertEqual(q.kind, "pdf")
        XCTAssertNotNil(q.modified)
        if case .within(let comps) = q.modified {
            XCTAssertEqual(comps.day, 7)
        } else {
            XCTFail("expected within(7d)")
        }
    }

    func testOlderThan() throws {
        let q = try FilterGrammar.parse("kind:pdf modified:>30d")
        if case .olderThan(let comps) = q.modified {
            XCTAssertEqual(comps.day, 30)
        } else {
            XCTFail("expected olderThan")
        }
    }

    func testPathExpandTilde() throws {
        let q = try FilterGrammar.parse("in:~/Documents kind:folder")
        XCTAssertEqual(q.kind, "folder")
        XCTAssertTrue(q.pathPrefix?.hasPrefix("/") == true)
        XCTAssertTrue(q.pathPrefix?.contains("Documents") == true)
    }

    func testNameFilter() throws {
        let q = try FilterGrammar.parse("name:Report")
        XCTAssertEqual(q.nameContains, "Report")
    }

    func testKindAliases() throws {
        XCTAssertEqual(try FilterGrammar.parse("kind:apps").kind, "app")
        XCTAssertEqual(try FilterGrammar.parse("type:png").kind, "image")
    }

    func testInvalidDateThrows() {
        XCTAssertThrowsError(try FilterGrammar.parse("modified:nope"))
    }

    func testEmptyFilterValueThrows() {
        XCTAssertThrowsError(try FilterGrammar.parse("kind:"))
    }

    func testRelativeDateWithinMatches() throws {
        let bound = try FilterGrammar.parseRelativeDate("<7d")
        let now = Date()
        let recent = now.addingTimeInterval(-3600)
        let old = now.addingTimeInterval(-86400 * 30)
        XCTAssertTrue(bound.matches(date: recent, now: now))
        XCTAssertFalse(bound.matches(date: old, now: now))
    }
}
