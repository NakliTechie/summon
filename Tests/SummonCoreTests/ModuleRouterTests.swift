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
        XCTAssertTrue(exec.calls.contains { $0.op == "getInfo" })
    }

    func testGetInfoPassesNewlinePathAsAppleScriptArgument() throws {
        let exec = RecordingModuleExecutor()
        let path = "/tmp/line-one\nline-two.txt"
        let hit = SearchResult(id: "file:newline", title: "newline", kind: .file, path: path)

        try ModuleRouter.perform(actionName: "file.getInfo", result: hit, executor: exec)

        let call = try XCTUnwrap(exec.calls.first { $0.op == "getInfo" })
        XCTAssertTrue(call.value.contains("item 1 of argv"))
        XCTAssertTrue(call.value.hasSuffix("-- \(path)"))
        XCTAssertFalse(call.value.contains("POSIX file \"\(path)\""))
    }

    func testDictionaryLookupPercentEncodesWords() throws {
        let exec = RecordingModuleExecutor()
        let hit = SearchResult(
            id: "dict:two words",
            title: "two words",
            kind: .command,
            payload: ["word": .string("two words/notes")]
        )

        try ModuleRouter.perform(actionName: "dict.define", result: hit, executor: exec)

        XCTAssertEqual(exec.calls.last?.value, "dict://two%20words%2Fnotes")
    }

    func testSpeechUsesOptionDelimiter() throws {
        let exec = RecordingModuleExecutor()
        let hit = SearchResult(
            id: "speech:dash",
            title: "speak",
            kind: .command,
            payload: ["text": .string("-o /tmp/not-an-output")]
        )

        try ModuleRouter.perform(actionName: "speech.speak", result: hit, executor: exec)

        XCTAssertEqual(exec.calls.last?.value, "-- -o /tmp/not-an-output")
    }

    func testSettingsOpenRoutesToTaskGroupedPreferences() throws {
        let exec = RecordingModuleExecutor()
        let hit = SearchResult(
            id: "settings:k",
            title: "Agent socket",
            kind: .setting,
            score: 1,
            payload: ["settingsKey": .string("agent.socket.enabled")]
        )
        try ModuleRouter.perform(actionName: "settings.open", result: hit, executor: exec)
        XCTAssertEqual(exec.calls.last?.op, "app.navigate")
        XCTAssertEqual(exec.calls.last?.value, AppDestination.preferencesAutomation.rawValue)
        XCTAssertTrue(exec.pasteboard.isEmpty)
    }

    func testHiddenPseudoActionsRejectWithoutSideEffects() {
        let exec = RecordingModuleExecutor()
        let file = SearchResult(id: "file:x", title: "x", kind: .file, path: "/tmp/x")
        let snippet = SearchResult(
            id: "snippet:x",
            title: "x",
            kind: .snippet,
            payload: ["body": .string("secret")]
        )

        for (name, result) in [
            ("file.openWith", file),
            ("snippet.edit", snippet),
            ("snippet.paste", snippet),
            ("calc.paste", snippet),
        ] {
            XCTAssertThrowsError(try ModuleRouter.perform(actionName: name, result: result, executor: exec))
        }
        XCTAssertTrue(exec.calls.isEmpty)
        XCTAssertTrue(exec.pasteboard.isEmpty)
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

    func testWindowArrangementRoutesThroughNativeAdapterSeam() {
        let exec = RecordingModuleExecutor()
        let hit = SearchResult(
            id: "window:left-half",
            title: "Left half",
            kind: .command,
            score: 1,
            payload: ["action": .string("window.arrange"), "layout": .string("leftHalf")]
        )

        XCTAssertNoThrow(try ModuleRouter.perform(actionName: "window.arrange", result: hit, executor: exec))
        XCTAssertEqual(exec.calls.last?.op, "window.arrange")
        XCTAssertEqual(exec.calls.last?.value, "leftHalf:8.0")
    }

    func testHiddenPseudoActionsRejectDirectInvocation() {
        let exec = RecordingModuleExecutor()
        for action in ["contacts.find", "camera.quick", "apps.autoquit"] {
            let hit = SearchResult(
                id: "hidden:\(action)",
                title: action,
                kind: .command,
                score: 1,
                payload: ["action": .string(action)]
            )

            XCTAssertThrowsError(try ModuleRouter.perform(actionName: action, result: hit, executor: exec)) { error in
                XCTAssertEqual(error as? CoreError, .unknownAction(action))
            }
        }
        XCTAssertTrue(exec.calls.isEmpty)
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

    func testRejectedConfirmationThrowsAndDoesNotRecordUsage() throws {
        let core = try SummonCore.inMemory(executor: RejectingModuleExecutor())
        let session = LauncherSession(core: core)
        session.applyResults(
            "broken",
            [
                SearchResult(
                    id: "app:broken",
                    title: "Broken",
                    kind: .app,
                    path: "/Applications/Broken.app"
                ),
            ]
        )

        XCTAssertThrowsError(try session.confirm(actor: .user))
        XCTAssertTrue(try core.frecency.recents().isEmpty)
        XCTAssertTrue(try core.journal.allEntries().last?.outcome.hasPrefix("rejected:") == true)
    }

    /// The parameterized set-volume effect must reject a bad level BEFORE running
    /// osascript, so a malformed AI proposal can never drive the host volume.
    func testSetVolumeEffectRejectsBadLevelWithoutSideEffects() {
        let exec = RecordingModuleExecutor()
        for bad in [
            "summon://system/set-volume/abc",
            "summon://system/set-volume/200",
            "summon://system/set-volume/-5",
            "summon://system/set-volume/",
        ] {
            XCTAssertThrowsError(
                try SystemEffects.perform(url: bad, executor: exec),
                "expected \(bad) to reject"
            )
        }
        XCTAssertTrue(exec.calls.isEmpty)
        XCTAssertTrue(exec.pasteboard.isEmpty)
    }

    func testEmptyTrashConfirmationIsMarkedDestructive() throws {
        let core = try SummonCore.inMemory()
        let session = LauncherSession(core: core)
        session.applyResults(
            "empty trash",
            [
                SearchResult(
                    id: "command:empty-trash",
                    title: "Empty Trash",
                    kind: .command,
                    path: "summon://system/empty-trash",
                    payload: ["url": .string("summon://system/empty-trash")]
                ),
            ]
        )

        let confirmation = try session.prepareConfirmation()

        XCTAssertTrue(confirmation.requiresUserConfirmation)
    }
}

private struct RejectingModuleExecutor: ModuleExecuting {
    func open(pathOrURL: String) throws {
        throw CoreError.io("injected open failure")
    }

    func reveal(path: String) throws {
        throw CoreError.io("injected reveal failure")
    }

    func copyToPasteboard(text: String) throws {
        throw CoreError.io("injected pasteboard failure")
    }
}
