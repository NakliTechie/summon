import XCTest
@testable import SummonAI

/// Live L1 probe on the designated M4 gate host. Skips cleanly if AI off.
final class L1LiveProbeTests: XCTestCase {
    func testL1AvailabilityProbe() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("L1 requires macOS 26+")
        }
        let avail = await AppleFoundationModelRung().availability()
        switch avail {
        case .available:
            break
        case .unavailable(let reason):
            throw XCTSkip("L1 unavailable: \(reason)")
        }
    }

    func testL1CompleteWhenAvailable() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("L1 requires macOS 26+")
        }
        let rung = AppleFoundationModelRung()
        guard (await rung.availability()).isAvailable else {
            throw XCTSkip("Enable Apple Intelligence to exercise L1")
        }
        let completion = try await rung.complete(prompt: "Reply with exactly the word: pong")
        XCTAssertEqual(completion.rung, .l1Apple)
        XCTAssertFalse(completion.text.isEmpty)
        XCTAssertEqual(completion.egressSummary, "")
    }
}
