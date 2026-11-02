import XCTest
@testable import SummonAI

final class DeadlineTests: XCTestCase {
    private struct TimedOut: Error {}

    func testReturnsTheResultWhenItArrivesInTime() async throws {
        let value = try await withDeadline(seconds: 5, timeout: TimedOut()) { 42 }
        XCTAssertEqual(value, 42)
    }

    /// A model call stuck behind a busy system does not honour cancellation. The
    /// deadline must still return on time (the 2026-11-02 weather question hung 46 s).
    func testStopsWaitingOnACallThatIgnoresCancellation() async {
        let started = Date()
        do {
            _ = try await withDeadline(seconds: 0.3, timeout: TimedOut()) { () -> Int in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } // never resumes
                return 1
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error is TimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testPassesAnOperationErrorThrough() async {
        struct Boom: Error {}
        do {
            _ = try await withDeadline(seconds: 5, timeout: TimedOut()) { () -> Int in throw Boom() }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }
}
