import XCTest
@testable import SummonAI

final class L0FallbackTests: XCTestCase {
    func testL0UnavailableWithoutConsent() async {
        let store = MemoryL0WeightStore()
        let l0 = L0PackagedModelRung(store: store, engine: FakeL0InferenceEngine())
        let avail = await l0.availability()
        XCTAssertFalse(avail.isAvailable)
    }

    func testL0AvailableAfterConsentAndWeights() async throws {
        let store = MemoryL0WeightStore()
        let l0 = L0PackagedModelRung(store: store, engine: FakeL0InferenceEngine())
        l0.grantConsent()
        store.markWeightsPresent(l0.manifest.modelID)
        let avail = await l0.availability()
        XCTAssertTrue(avail.isAvailable)
        let c = try await l0.complete(prompt: "hello L0")
        XCTAssertEqual(c.rung, .l0Packaged)
        XCTAssertTrue(c.text.contains("L0-staged"))
        XCTAssertEqual(c.egressSummary, "")
    }

    func testLadderPrefersL0WhenL1Down() async throws {
        let store = MemoryL0WeightStore()
        let l0 = L0PackagedModelRung(store: store, engine: FakeL0InferenceEngine())
        l0.grantConsent()
        store.markWeightsPresent(l0.manifest.modelID)
        let ladder = AILadder.testingL0Fallback(l0: l0, l1Available: false)
        let preferred = await ladder.preferredRung()
        XCTAssertEqual(preferred?.id, .l0Packaged)
        let c = try await ladder.complete(prompt: "fallback")
        XCTAssertEqual(c.rung, .l0Packaged)
    }

    func testNLCommandSidecarGradesJSON() throws {
        let out = """
        Here you go:
        {"v":1,"action":"settings.set","key":"theme","value":"dark"}
        """
        let parsed = try NLCommandSidecar.parse(output: out)
        XCTAssertEqual(parsed.actionName, "settings.set")
        if case .settingsSet(let k, let v) = parsed.coreAction {
            XCTAssertEqual(k, "theme")
            XCTAssertEqual(v, .string("dark"))
        } else {
            XCTFail("wrong action")
        }
    }

    func testNLCommandSidecarRejectsGarbage() {
        XCTAssertThrowsError(try NLCommandSidecar.parse(output: "just prose no json"))
    }

    func testRAMHeuristic() {
        let gb = MachineMemory.totalRAMGB()
        XCTAssertGreaterThan(gb, 0)
        let m = MachineMemory.recommendedL0Manifest()
        if gb >= 16 {
            XCTAssertEqual(m.modelID, L0ModelManifest.e4bOptional.modelID)
        } else {
            XCTAssertEqual(m.modelID, L0ModelManifest.e2bDefault.modelID)
        }
    }
}
