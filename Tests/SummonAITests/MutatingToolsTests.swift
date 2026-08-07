import XCTest
@testable import SummonAI
import SummonCore

/// The harness-driven action path: a query is classified, parsed into a typed
/// CoreAction, and run (safe) or staged (destructive) by the harness — never by the
/// on-device model calling a tool. Deterministic; no live model.
final class MutatingToolsTests: XCTestCase {
    // MARK: - Intent classifier

    func testMutatingIntentFiresOnImperativeCreateSnippet() {
        XCTAssertEqual(
            SystemReaders.mutatingIntents(for: "make a snippet called sig with my email"),
            [.createSnippet]
        )
        XCTAssertEqual(
            SystemReaders.mutatingIntents(for: "save this as a snippet named addr"),
            [.createSnippet]
        )
    }

    func testReportedVolumeQueryClassifiesAsAnAction() {
        XCTAssertEqual(SystemReaders.mutatingIntents(for: "set the volume to 30%"), [.setVolume])
        XCTAssertEqual(SystemReaders.mutatingIntents(for: "set the volume to 30"), [.setVolume])
    }

    func testMutatingIntentStrippedForInformationQuestions() {
        XCTAssertTrue(SystemReaders.mutatingIntents(for: "what is a snippet").isEmpty)
        XCTAssertTrue(SystemReaders.mutatingIntents(for: "how do i create a snippet").isEmpty)
        XCTAssertTrue(SystemReaders.mutatingIntents(for: "how do i set the volume").isEmpty)
        XCTAssertTrue(SystemReaders.mutatingIntents(for: "turn up the volume").isEmpty)
    }

    // MARK: - Parser (NL → typed CoreAction, deterministic)

    func testParserBuildsSetVolumeModuleRun() {
        guard case let .moduleRun(name, _, path, _)? =
            SummonActionParser.parse("set the volume to 30%") else {
            return XCTFail("expected moduleRun")
        }
        XCTAssertEqual(name, "command.run")
        XCTAssertEqual(path, "summon://system/set-volume/30")
        XCTAssertEqual(SummonActionParser.volumeLevel("mute the volume 0"), 0)
        XCTAssertEqual(SummonActionParser.volumeLevel("set volume to 200"), 100)
    }

    func testParserBuildsSnippetAndQuicklink() {
        guard case let .snippetUpsert(_, sName, body, _)? =
            SummonActionParser.parse("make a snippet called sig that says Best, Chirag") else {
            return XCTFail("expected snippetUpsert")
        }
        XCTAssertEqual(sName, "sig")
        XCTAssertEqual(body, "Best, Chirag")

        guard case let .quicklinkUpsert(_, qName, url, _)? =
            SummonActionParser.parse("make a quicklink called gh for https://github.com") else {
            return XCTFail("expected quicklinkUpsert")
        }
        XCTAssertEqual(qName, "gh")
        XCTAssertEqual(url, "https://github.com")
    }

    func testParserReturnsNilForQuestionsAndNonActions() {
        XCTAssertNil(SummonActionParser.parse("who wrote 1984"))
        XCTAssertNil(SummonActionParser.parse("how do i set the volume"))
        XCTAssertNil(SummonActionParser.parse("what is a snippet"))
        XCTAssertNil(SummonActionParser.parse("the capital of australia"))
    }

    // MARK: - Harness runs safe actions and reports truthfully

    func testSafeActionRunsImmediatelyAndReportsTruthfully() async throws {
        // A snippet is a store action (no system effect), safe to run in a test.
        let ladder = AILadder.testing(fake: FakeModelRung())
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let service = SummonAIService(ladder: ladder, core: core)

        let response = try await service.respond(
            prompt: "make a snippet called sig that says Best, Chirag", actor: .user
        )
        guard case let .performed(text) = response.kind else {
            return XCTFail("expected performed, got \(response.kind)")
        }
        XCTAssertTrue(text.contains("sig"), "result should name what happened: \(text)")
        let snippets = try core.snippets.all()
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets.first?.name, "sig")
        XCTAssertEqual(snippets.first?.body, "Best, Chirag")
    }

    func testPlainQuestionIsNotInterceptedAsAnAction() async throws {
        let ladder = AILadder.testing(fake: FakeModelRung(cannedText: "answer-text"))
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let service = SummonAIService(ladder: ladder, core: core)

        let response = try await service.respond(prompt: "a plain question about history", actor: .user)
        guard case let .answer(text) = response.kind else {
            return XCTFail("expected answer, got \(response.kind)")
        }
        XCTAssertTrue(text.contains("answer-text"))
        XCTAssertTrue(try core.snippets.all().isEmpty)
    }

    func testTrashSynonymsClassifyAndParseAsEmptyTrash() {
        // Field report: "empty the bin" / "clear the trash" were web-searched.
        for query in ["empty the trash", "empty the bin", "clear the trash", "empty trash"] {
            XCTAssertTrue(
                SystemReaders.mutatingIntents(for: query).contains(.emptyTrash),
                "not classified as an action: \(query)"
            )
            XCTAssertNotNil(SummonActionParser.parse(query), "no action parsed for: \(query)")
        }
    }

    func testDestructiveSystemActionStagesNeverRuns() async throws {
        let action = try XCTUnwrap(SummonActionParser.parse("empty the trash"))
        guard case let .moduleRun(_, _, path, _) = action else {
            return XCTFail("expected moduleRun")
        }
        XCTAssertEqual(path, "summon://system/empty-trash")
        XCTAssertTrue(DestructiveGuard.isDestructive(action), "empty-trash must be destructive")

        let ladder = AILadder.testing(fake: FakeModelRung())
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let service = SummonAIService(ladder: ladder, core: core)
        let response = try await service.respond(prompt: "empty the trash", actor: .user)
        guard case .staged = response.kind else {
            return XCTFail("expected staged, got \(response.kind)")
        }
        XCTAssertEqual(try core.staged.list(state: "staged").count, 1)
    }

    func testExpandedSafeSystemActionsParseAsSafe() {
        let dark = try? XCTUnwrap(SummonActionParser.parse("switch to dark mode"))
        XCTAssertNotNil(dark)
        XCTAssertFalse(DestructiveGuard.isDestructive(dark!))
        let display = try? XCTUnwrap(SummonActionParser.parse("turn off the screen"))
        XCTAssertNotNil(display)
        XCTAssertFalse(DestructiveGuard.isDestructive(display!))
        guard case let .moduleRun(name, _, _, payload)? = SummonActionParser.parse("say hello world") else {
            return XCTFail("expected speech moduleRun")
        }
        XCTAssertEqual(name, "speech.speak")
        XCTAssertEqual(payload["text"]?.stringValue, "hello world")
    }

    func testUnsupportedActionsDeclineDeterministically() {
        XCTAssertNotNil(SummonActionParser.declineReason("email bob about lunch"))
        XCTAssertNotNil(SummonActionParser.declineReason("remind me to pay rent tomorrow"))
        XCTAssertNotNil(SummonActionParser.declineReason("add lunch with Jo to my calendar"))
        XCTAssertNotNil(SummonActionParser.declineReason("play some Radiohead"))
        XCTAssertNotNil(SummonActionParser.declineReason("move budget.xlsx to Documents"))
        // Questions and non-actions are NOT declined — they still answer/search.
        XCTAssertNil(SummonActionParser.declineReason("what's my next meeting"))
        XCTAssertNil(SummonActionParser.declineReason("who wrote 1984"))
    }

    func testUnsupportedActionRespondsWithHonestDeclineNotModel() async throws {
        let ladder = AILadder.testing(fake: FakeModelRung(cannedText: "MODEL-IMPROVISED"))
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let service = SummonAIService(ladder: ladder, core: core)
        let response = try await service.respond(prompt: "remind me to pay rent tomorrow", actor: .user)
        guard case let .answer(text) = response.kind else {
            return XCTFail("expected answer, got \(response.kind)")
        }
        XCTAssertTrue(text.contains("can't set reminders"))
        XCTAssertFalse(text.contains("MODEL-IMPROVISED"), "must not reach the model")
    }

    func testSetVolumeClassifiesAsSafeNotDestructive() {
        // The whole point of "do safe / stage destructive": volume runs, sleep stages.
        let setVolume = SummonActionParser.parse("set the volume to 30")!
        XCTAssertFalse(DestructiveGuard.isDestructive(setVolume))
        let sleep = CoreAction.moduleRun(
            name: "command.run", targetID: "command:sleep",
            path: "summon://system/sleep", payload: [:]
        )
        XCTAssertTrue(DestructiveGuard.isDestructive(sleep))
    }
}
