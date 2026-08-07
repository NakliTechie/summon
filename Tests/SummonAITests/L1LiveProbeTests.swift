import XCTest
@testable import SummonAI

/// Live L1 probe on the designated M4 gate host. Skips cleanly if AI off.
final class L1LiveProbeTests: XCTestCase {
    func testL1AvailabilityProbe() async throws {
        try requireExplicitLiveProbe()
        guard #available(macOS 26.0, *) else {
            return XCTFail("L1 live probe requires macOS 26+")
        }
        let avail = await AppleFoundationModelRung().availability()
        switch avail {
        case .available:
            break
        case .unavailable(let reason):
            XCTFail("L1 unavailable: \(reason)")
        }
    }

    func testL1CompleteWhenAvailable() async throws {
        try requireExplicitLiveProbe()
        guard #available(macOS 26.0, *) else {
            return XCTFail("L1 live probe requires macOS 26+")
        }
        let rung = AppleFoundationModelRung()
        guard (await rung.availability()).isAvailable else {
            return XCTFail("Enable Apple Intelligence to exercise L1")
        }
        let completion = try await rung.complete(prompt: "Reply with exactly the word: pong")
        XCTAssertEqual(completion.rung, .l1Apple)
        XCTAssertFalse(completion.text.isEmpty)
        XCTAssertEqual(completion.egressSummary, "")
    }

    private func requireExplicitLiveProbe() throws {
        guard ProcessInfo.processInfo.environment["SUMMON_RUN_L1_LIVE"] == "1" else {
            throw XCTSkip("set SUMMON_RUN_L1_LIVE=1 to invoke Apple Foundation Models")
        }
    }
}
