import XCTest
@testable import SummonAI
import SummonCore

final class LocalModelRungTests: XCTestCase {
    struct FakeTransport: LocalModelTransport {
        let modelIDs: [String]
        let reply: String
        func models(baseURL: URL, authorization: EgressAuthorization?) async throws -> [String] {
            guard authorization?.permits(url: baseURL.appendingPathComponent("models"), purpose: .localModel) == true
            else { throw CoreError.store("unauthorized") }
            return modelIDs
        }
        func chat(
            baseURL: URL, model: String, prompt: String, authorization: EgressAuthorization?
        ) async throws -> String {
            guard authorization?.permits(url: baseURL.appendingPathComponent("chat/completions"), purpose: .localModel) == true
            else { throw CoreError.store("unauthorized") }
            return reply
        }
    }

    private func loopbackRung(_ transport: FakeTransport, core: SummonCore) -> LocalModelRung {
        LocalModelRung(
            core: core, transport: transport,
            candidates: [URL(string: "http://127.0.0.1:11434/v1")!]
        )
    }

    func testAvailableWhenServerListsModels() async throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let rung = loopbackRung(FakeTransport(modelIDs: ["qwen2.5:3b"], reply: "x"), core: core)
        let available = (await rung.availability()).isAvailable
        XCTAssertTrue(available)
    }

    func testUnavailableWhenNoModels() async throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let rung = loopbackRung(FakeTransport(modelIDs: [], reply: "x"), core: core)
        let available = (await rung.availability()).isAvailable
        XCTAssertFalse(available)
    }

    func testCompleteReturnsServerReplyAndJournalsEgress() async throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let rung = loopbackRung(FakeTransport(modelIDs: ["m"], reply: "PONG"), core: core)
        let completion = try await rung.complete(prompt: "ping")
        XCTAssertEqual(completion.text, "PONG")
        XCTAssertEqual(completion.rung, .localServer)
        // The loopback call was journaled as a .localModel egress.
        let journaled = try core.journal.allEntries().contains { entry in
            if case .egressRequested(let purpose, _) = entry.action { return purpose == "user.ai.local" }
            return false
        }
        XCTAssertTrue(journaled)
    }

    func testEnsureLocalModelRungInstallsItAfterAppleIdempotently() async throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let ladder = AILadder()
        ladder.ensureLocalModelRung(core: core)
        XCTAssertEqual(ladder.rungs.first?.id, .appleFM, "Apple FM stays first")
        XCTAssertEqual(ladder.rungs.last?.id, .localServer, "local rung is the fallback")
        ladder.ensureLocalModelRung(core: core)
        XCTAssertEqual(ladder.rungs.filter { $0.id == .localServer }.count, 1, "idempotent")
    }

    private struct StubRung: ModelRung, Sendable {
        let id: ModelRungID
        let available: Bool
        var displayName: String { id.rawValue }
        func availability() async -> RungAvailability {
            available ? .available : .unavailable(reason: "stub")
        }
        func complete(prompt: String) async throws -> ModelCompletion {
            ModelCompletion(text: id.rawValue, rung: id)
        }
    }

    /// Decided 2026-10-30: Apple FM first, because a cold local server can take
    /// minutes to load its model; the server answers only when Apple FM cannot.
    func testPreferredRungIsAppleFirstThenLocalServer() async {
        let both = AILadder(rungs: [
            StubRung(id: .localServer, available: true),
            StubRung(id: .appleFM, available: true),
        ])
        let first = await both.preferredRung()
        XCTAssertEqual(first?.id, .appleFM)

        let appleDown = AILadder(rungs: [
            StubRung(id: .appleFM, available: false),
            StubRung(id: .localServer, available: true),
        ])
        let fallback = await appleDown.preferredRung()
        XCTAssertEqual(fallback?.id, .localServer)
    }

    func testRungIDsStoreReadableNames() {
        XCTAssertEqual(ModelRungID.appleFM.rawValue, "apple-fm")
        XCTAssertEqual(ModelRungID.localServer.rawValue, "local-server")
        XCTAssertEqual(ModelRungID.mlx.rawValue, "mlx")
        XCTAssertNil(ModelRungID(rawValue: "L1"), "legacy names are migrated in the store, not decoded")
    }

    /// Live check against a real Ollama / LM Studio on this machine.
    func testLiveLocalModelAnswers() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SUMMON_RUN_LOCALMODEL_LIVE"] == "1",
            "Set SUMMON_RUN_LOCALMODEL_LIVE=1 with Ollama/LM Studio running."
        )
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let rung = LocalModelRung(core: core)
        guard (await rung.availability()).isAvailable else {
            return XCTFail("no local model server detected on :11434 or :1234")
        }
        let completion = try await rung.complete(prompt: "Reply with exactly one word: pong")
        print("live local model reply: \(completion.text.prefix(80))")
        XCTAssertFalse(completion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
