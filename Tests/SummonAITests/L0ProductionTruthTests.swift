import XCTest
@testable import SummonAI

final class L0ProductionTruthTests: XCTestCase {
    func testProductionWithoutBinaryIsUnavailable() async {
        let store = MemoryL0WeightStore()
        // Force unavailable engine regardless of host PATH
        let l0 = L0PackagedModelRung(store: store, engine: UnavailableL0InferenceEngine())
        l0.grantConsent()
        store.markWeightsPresent(l0.manifest.modelID)
        let avail = await l0.availability()
        XCTAssertFalse(avail.isAvailable)
        if case .unavailable(let reason) = avail {
            XCTAssertTrue(reason.contains("mlx") || reason.contains("not installed"))
        } else {
            XCTFail("expected unavailable")
        }
    }

    func testProductionDoesNotUseFakeEngineWhenBinaryMissing() {
        // Simulate production factory path by constructing Unavailable
        let store = MemoryL0WeightStore()
        let l0 = L0PackagedModelRung.production(store: store)
        // On CI without mlx, engine must not be FakeL0InferenceEngine
        if MLXProcessL0Engine.detectBinary() == nil {
            XCTAssertTrue(l0.engine is UnavailableL0InferenceEngine)
        } else {
            XCTAssertTrue(l0.engine is MLXProcessL0Engine)
        }
    }

    func testDigestAndPinRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-l0-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.json")
        try Data(#"{"model_type":"test"}"#.utf8).write(to: config)
        let digest = try L0ModelFetch.digestConfig(at: dir)
        XCTAssertEqual(digest.count, 64)
        try L0ModelFetch.writePin(digest: digest, modelDir: dir)
        XCTAssertEqual(L0ModelFetch.readPin(modelDir: dir), digest)
        let manifest = L0ModelManifest(
            modelID: "t",
            displayName: "t",
            quant: "4",
            minRAMGB: 8,
            approxDownloadBytes: 1,
            sha256: "PENDING_PIN_AFTER_FIRST_FETCH",
            hfRepo: "x/y"
        )
        try L0ModelFetch.verifyInstalled(modelDir: dir, manifest: manifest)
    }

    func testVerifyFailsOnMismatch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-l0-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"model_type":"test"}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        try L0ModelFetch.writePin(digest: String(repeating: "0", count: 64), modelDir: dir)
        let manifest = L0ModelManifest.e2bDefault
        XCTAssertThrowsError(try L0ModelFetch.verifyInstalled(modelDir: dir, manifest: manifest))
    }
}
