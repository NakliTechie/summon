import XCTest
@testable import SummonCore

final class LatencyProbeTests: XCTestCase {
    func testP95IndexFor100Samples() {
        let n = 100
        let rank = max(1, Int((0.95 * Double(n)).rounded(.up)))
        let idx = min(n - 1, rank - 1)
        XCTAssertEqual(idx, 94)
    }

    func testP95IndexFor20Samples() {
        let n = 20
        let rank = max(1, Int((0.95 * Double(n)).rounded(.up)))
        let idx = min(n - 1, rank - 1)
        XCTAssertEqual(idx, 18)
    }

    func testMeasureRuns() throws {
        let sample = try LatencyProbe.measure(label: "noop", iterations: 20) {}
        XCTAssertEqual(sample.iterations, 20)
        XCTAssertGreaterThanOrEqual(sample.milliseconds, 0)
    }
}
