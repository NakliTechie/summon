import XCTest
@testable import SummonAI
@testable import SummonCore

final class SidecarTests: XCTestCase {
    func testQuickFixStages() async throws {
        let fake = FakeModelRung(cannedText: "rewritten")
        let qf = QuickFixSidecar(rung: fake)
        let p = try await qf.rewrite(selection: "hello", tone: "formal")
        XCTAssertEqual(p.state, "staged")
        XCTAssertTrue(p.output.contains("rewritten"))
    }

    func testTranslateStages() async throws {
        let fake = FakeModelRung(cannedText: "hola")
        let t = TranslateSidecar(rung: fake)
        let p = try await t.translate(text: "hello", to: "es")
        XCTAssertTrue(p.output.contains("hola"))
    }

    func testScreenshotAsk() async throws {
        let fake = FakeModelRung(cannedText: "a button")
        let s = ScreenshotAskSidecar(rung: fake)
        let p = try await s.ask(ocrText: "OK Cancel", question: "what buttons?")
        XCTAssertTrue(p.output.contains("button"))
    }

    func testDictationStage() {
        let d = DictationSidecar()
        let p = d.stageTranscript("hello world")
        XCTAssertEqual(p.output, "hello world")
        XCTAssertEqual(p.rung, "dictation")
    }

    func testSemanticRank() {
        let ranked = SemanticSearchS3.rank(
            query: "quarterly revenue",
            documents: [
                (id: "a", text: "cat"),
                (id: "b", text: "quarterly revenue report"),
            ]
        )
        XCTAssertEqual(ranked.first?.id, "b")
    }

    func testNLShellStages() async throws {
        let fake = FakeModelRung(cannedText: "ls -la")
        let nl = NLSurfaceSidecar(rung: fake)
        let p = try await nl.shell(from: "list files")
        XCTAssertTrue(p.output.contains("ls"))
        XCTAssertEqual(p.state, "staged")
    }

    func testLocalRuntimeDetectStruct() {
        let d = LocalRuntimeDetect(ollama: false, lmStudio: false, hasBYOK: false)
        XCTAssertFalse(d.ollama)
    }
}
