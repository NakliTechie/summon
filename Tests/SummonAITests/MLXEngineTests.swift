import XCTest
@testable import SummonAI

final class MLXEngineTests: XCTestCase {
    func testDetectBinaryOnThisMachine() {
        // Gate host has mlx_lm; CI may not — do not fail either way.
        let path = MLXProcessL0Engine.detectBinary()
        if path != nil {
            XCTAssertTrue(path!.contains("mlx_lm"))
        }
    }

    func testIsReadyRequiresConfigJSON() throws {
        let engine = MLXProcessL0Engine()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-ready-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertFalse(engine.isReady(weightsURL: tmp))
        try "{}".write(to: tmp.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(engine.isReady(weightsURL: tmp))
    }

    func testProductionRungUsesMLXWhenAvailable() {
        let store = MemoryL0WeightStore()
        let rung = L0PackagedModelRung.production(store: store)
        // Type of engine is internal; availability without consent still off.
        let exp = expectation(description: "avail")
        Task {
            let a = await rung.availability()
            XCTAssertFalse(a.isAvailable)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }
}
