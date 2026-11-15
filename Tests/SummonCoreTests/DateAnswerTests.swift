import XCTest
@testable import SummonCore

/// Calendar questions are answered on the Mac (2026-11-15: Apple FM called Friday
/// 20 November 2026 a Saturday, and the web route returned unrelated pages).
final class DateAnswerTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }
    /// Sunday 15 November 2026, 13:20 IST.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 13, minute: 20))!
    }

    private func answer(_ query: String) -> SearchResult? {
        DateAnswer.result(for: query, now: now, calendar: calendar)
    }

    func testWhatDayIsADateWithNoYear() throws {
        let row = try XCTUnwrap(answer("what day is 20th nov?"))
        XCTAssertEqual(row.kind, .calculation)
        XCTAssertTrue(row.title.contains("Friday"), row.title)
        XCTAssertTrue(row.title.contains("2026"), row.title)
        XCTAssertEqual(row.subtitle?.hasPrefix("in 5 days"), true, row.subtitle ?? "")
    }

    func testOtherPhrasings() throws {
        XCTAssertTrue(try XCTUnwrap(answer("what day of the week is 1 jan 2027")).title.contains("Friday"))
        XCTAssertTrue(try XCTUnwrap(answer("which day was 15 august 1947")).title.contains("Friday"))
        XCTAssertTrue(try XCTUnwrap(answer("25 december is what day")).title.contains("Friday"))
        XCTAssertTrue(try XCTUnwrap(answer("what day is tomorrow")).title.contains("Monday"))
    }

    func testADateWithNoYearThatHasPassedMeansNextYear() throws {
        let row = try XCTUnwrap(answer("what day is 1 jan"))
        XCTAssertTrue(row.title.contains("2027"), row.title)
        XCTAssertTrue(row.title.contains("Friday"), row.title)
    }

    func testDaysUntilAndSince() throws {
        XCTAssertEqual(try XCTUnwrap(answer("how many days until 25 dec")).title.hasPrefix("40 days until"), true)
        XCTAssertEqual(try XCTUnwrap(answer("days since 1 nov 2026")).title.hasPrefix("14 days since"), true)
    }

    func testLeavesOtherQuestionsAlone() {
        XCTAssertNil(answer("what day is my dentist appointment"))
        XCTAssertNil(answer("what is the weather today like?"))
        XCTAssertNil(answer("how to get to france from japan"))
        XCTAssertNil(answer("safari"))
    }

    /// Codex review 2026-11-15.
    func testPastQuestionsLookBackLeapDaysAndTwoDigitYears() throws {
        XCTAssertEqual(try XCTUnwrap(answer("days since 1 nov")).title.hasPrefix("14 days since"), true)
        XCTAssertTrue(try XCTUnwrap(answer("what day was 1 nov")).title.contains("2026"))
        let leap = try XCTUnwrap(answer("what day is 29 feb"))
        XCTAssertTrue(leap.title.contains("29") && leap.title.contains("2028"), leap.title)
        XCTAssertTrue(try XCTUnwrap(answer("what day is 04/01/30")).title.contains("2030"))
    }
}
