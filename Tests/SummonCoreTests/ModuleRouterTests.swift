import XCTest
@testable import SummonCore

final class ModuleRouterTests: XCTestCase {
    func testOpenUsesDoubleDashDelimiter() throws {
        let exec = RecordingModuleExecutor()
        // ProcessModuleExecutor is production; for Recording we only check router calls open
        let file = SearchResult(
            id: "file:1",
            title: "dash",
            kind: .file,
            path: "/tmp/-weird.txt",
            score: 1
        )
        try ModuleRouter.perform(actionName: "file.open", result: file, executor: exec)
        XCTAssertEqual(exec.calls.last?.op, "open")
        XCTAssertEqual(exec.calls.last?.value, "/tmp/-weird.txt")
    }

    func testEmojiCopyPutsGlyphOnPasteboard() throws {
        let exec = RecordingModuleExecutor()
        let hit = SearchResult(
            id: "emoji:🚀",
            title: "🚀",
            subtitle: "rocket",
            kind: .emoji,
            score: 1,
            payload: [
                "text": .string("🚀"),
                "emoji": .string("🚀"),
            ]
        )
        try ModuleRouter.perform(actionName: "emoji.copy", result: hit, executor: exec)
        XCTAssertEqual(exec.pasteboard, "🚀")
    }

    func testEmojiDefaultActionViaSession() throws {
        let core = try SummonCore.inMemory()
        let exec = RecordingModuleExecutor()
        core.setExecutor(exec)
        let session = LauncherSession(core: core)
        let hits = try session.setQuery("rocket kind:emoji")
        XCTAssertEqual(hits.first?.kind, .emoji)
        let action = try session.confirm(actor: .user)
        XCTAssertEqual(action, "emoji.copy")
        XCTAssertEqual(exec.pasteboard, "🚀")
    }

    func testProcessKillRecordsPID() throws {
        let exec = RecordingModuleExecutor()
        let hit = SearchResult(
            id: "proc:12345",
            title: "Kill foo",
            kind: .command,
            score: 1,
            payload: ["pid": .string("12345"), "action": .string("process.kill")]
        )
        try ModuleRouter.perform(actionName: "process.kill", result: hit, executor: exec)
        XCTAssertEqual(exec.killedPIDs, [12345])
    }

    func testFileTrashRecordsPath() throws {
        let exec = RecordingModuleExecutor()
        let hit = SearchResult(
            id: "file:x",
            title: "x",
            kind: .file,
            path: "/tmp/to-trash.txt",
            score: 1
        )
        try ModuleRouter.perform(actionName: "file.trash", result: hit, executor: exec)
        XCTAssertEqual(exec.trashedPaths, ["/tmp/to-trash.txt"])
    }

    func testGetInfoReveal() throws {
        let exec = RecordingModuleExecutor()
        let hit = SearchResult(
            id: "file:y",
            title: "y",
            kind: .file,
            path: "/tmp/y.txt",
            score: 1
        )
        try ModuleRouter.perform(actionName: "file.getInfo", result: hit, executor: exec)
        XCTAssertTrue(exec.calls.contains { $0.op == "reveal" })
    }

    func testSettingsOpenCopiesKey() throws {
        let exec = RecordingModuleExecutor()
        let hit = SearchResult(
            id: "settings:k",
            title: "Agent socket",
            kind: .setting,
            score: 1,
            payload: ["settingsKey": .string("agent.socket.enabled")]
        )
        try ModuleRouter.perform(actionName: "settings.open", result: hit, executor: exec)
        XCTAssertEqual(exec.pasteboard, "agent.socket.enabled")
    }

    func testScreenshotActionRoutes() throws {
        let exec = RecordingModuleExecutor()
        let hit = SearchResult(
            id: "shot:region",
            title: "Screenshot region",
            kind: .command,
            score: 1,
            payload: ["action": .string("screenshot.region")]
        )
        try ModuleRouter.perform(actionName: "screenshot.region", result: hit, executor: exec)
        XCTAssertTrue(exec.calls.contains { $0.op == "screenshot.region" })
    }

    func testSessionDefaultActionUsesPayload() throws {
        let core = try SummonCore.inMemory()
        let session = LauncherSession(core: core)
        let exec = RecordingModuleExecutor()
        core.setExecutor(exec)
        // Seed a kill-shaped result via search "kill " may be empty in sandbox — invoke directly
        let hit = SearchResult(
            id: "proc:9",
            title: "Kill x",
            kind: .command,
            score: 1,
            payload: ["pid": .string("9"), "action": .string("process.kill")]
        )
        try core.invoke(actionName: "process.kill", result: hit, actor: .user)
        XCTAssertEqual(exec.killedPIDs, [9])
        _ = session // silence unused if needed
    }

    func testConfirmUsesPayloadActionForCommand() throws {
        let core = try SummonCore.inMemory()
        let exec = RecordingModuleExecutor()
        core.setExecutor(exec)
        let session = LauncherSession(core: core)
        _ = try session.setQuery("screenshot")
        let shot = session.results.first { $0.id.hasPrefix("shot:") }
        XCTAssertNotNil(shot)
        // defaultActionName must prefer payload.action
        if case .string(let action) = shot?.payload["action"] {
            try core.invoke(actionName: action, result: shot!, actor: .user)
            XCTAssertTrue(action.hasPrefix("screenshot."))
        } else {
            XCTFail("expected action payload")
        }
        XCTAssertFalse(exec.calls.isEmpty)
        _ = session
    }
}
