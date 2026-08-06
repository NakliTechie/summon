import XCTest
@testable import SummonAI

final class SummonToolboxTests: XCTestCase {
    func testDatetimeReaderIsGroundedAndCarriesTimezone() {
        // A fixed instant so the assertion is deterministic across hosts.
        let fixed = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 UTC
        let text = SystemReaders.datetime(now: fixed)
        XCTAssertTrue(text.contains("2023"))
        XCTAssertTrue(text.contains(TimeZone.current.identifier))
    }

    func testSystemInfoReaderReportsLiveFacts() {
        let text = SystemReaders.systemInfo()
        XCTAssertTrue(text.contains("macOS:"))
        XCTAssertTrue(text.contains("Memory:"))
        XCTAssertTrue(text.contains("CPU cores:"))
    }

    func testIntentClassifierGatesToolsToOnTopicQueriesOnly() {
        // On-topic → the matching intent.
        XCTAssertEqual(SystemReaders.intents(for: "what is my battery percentage"), [.battery])
        XCTAssertEqual(SystemReaders.intents(for: "am i plugged in or on battery"), [.battery])
        XCTAssertEqual(SystemReaders.intents(for: "what time is it right now"), [.datetime])
        XCTAssertEqual(SystemReaders.intents(for: "what is today's date"), [.datetime])
        XCTAssertEqual(SystemReaders.intents(for: "how much memory does this mac have"), [.systemInfo])
        XCTAssertEqual(SystemReaders.intents(for: "how many cpu cores do i have"), [.systemInfo])

        // The bleed cases from the battery → NO tool (so nothing to bleed).
        XCTAssertTrue(SystemReaders.intents(for: "convert 100 kilometers to miles").isEmpty)
        XCTAssertTrue(SystemReaders.intents(for: "asdf qwerty zxcv").isEmpty)
        XCTAssertTrue(SystemReaders.intents(for: "give me three names for a productivity app").isEmpty)
        XCTAssertTrue(SystemReaders.intents(for: "tell me about my calendar for tomorrow").isEmpty)
        XCTAssertTrue(SystemReaders.intents(for: "what is the latest version of swift").isEmpty)
    }

    func testBatteryReaderReturnsAGroundedNonEmptyFact() {
        let text = SystemReaders.battery()
        XCTAssertFalse(text.isEmpty)
        // On any Mac it is one of: a percentage, no-battery, or unavailable —
        // never an invented number, because it reads IOKit directly.
        let grounded = text.contains("Battery:")
            || text.lowercased().contains("no internal battery")
            || text.lowercased().contains("unavailable")
        XCTAssertTrue(grounded, "unexpected battery text: \(text)")
    }
}
