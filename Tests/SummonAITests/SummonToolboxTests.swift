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
