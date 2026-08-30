import XCTest
@testable import SummonAI
import SummonCore

/// The harness truthfulness guarantee, pinned end-to-end:
///
///   **Summon never reports an action it did not actually perform.**
///
/// `SummonAIService.performOrStage` maps the ACTUAL action-bus outcome
/// (`.applied` / `.rejected` / `.staged`) onto the reported shape
/// (`.performed` / `.answer` / `.staged`). The on-device model is never the actor
/// and is never the source of a success claim — `SummonActionParser` parses the
/// typed action deterministically, the harness runs the safe ones and stages the
/// destructive ones, and the report is derived from the machine's real outcome.
///
/// Every test here is machine-safe: it exercises only store actions (snippets,
/// settings) and the staging path, so no real system effect (volume, trash, sleep)
/// is ever dispatched. See `docs/harness.md` for the design.
final class HarnessTruthfulnessTests: XCTestCase {
    /// A model rigged to CLAIM success on every completion. If this text ever
    /// surfaces in a performed / staged / declined response, the harness leaked the
    /// model's narration into a truth claim — the exact failure this design removes.
    private static let liar = "I DID IT — your action completed successfully."

    private func makeService() throws -> (SummonAIService, SummonCore, RecordingModuleExecutor) {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let executor = RecordingModuleExecutor()
        core.setExecutor(executor)
        let service = SummonAIService(
            ladder: .testing(fake: FakeModelRung(cannedText: Self.liar)),
            core: core
        )
        return (service, core, executor)
    }

    // MARK: - 1. A safe action truly executes, and the report matches reality

    func testSafeActionExecutesAndTheReportMatchesTheAppliedOutcome() async throws {
        let (service, core, _) = try makeService()

        let response = try await service.respond(
            prompt: "make a snippet called sig that says Best, Chirag", actor: .user
        )

        // Reported as performed …
        guard case let .performed(text) = response.kind else {
            return XCTFail("expected .performed, got \(response.kind)")
        }
        // … the store actually changed (execution is real, not narrated) …
        let snippets = try core.snippets.all()
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets.first?.name, "sig")
        XCTAssertEqual(snippets.first?.body, "Best, Chirag")
        // … and the report is harness-derived — it names the real action, never the
        // model's canned "I did it" claim.
        XCTAssertTrue(text.contains("sig"), "performed text should name the action: \(text)")
        XCTAssertFalse(text.contains(Self.liar), "model narration must not surface in a truth claim")
    }

    /// The append-only audit trail agrees: a performed safe action leaves exactly
    /// one `applied` snippet.upsert row. "Reported" and "actually happened" match on
    /// disk, not just in the return value.
    func testPerformedSafeActionLeavesExactlyOneAppliedJournalRow() async throws {
        let (service, core, _) = try makeService()

        _ = try await service.respond(prompt: "make a snippet called sig that says hi", actor: .user)

        let upserts = try core.journal.allEntries().filter { $0.action.name == "snippet.upsert" }
        XCTAssertEqual(upserts.count, 1, "exactly one snippet.upsert should be journaled")
        XCTAssertEqual(upserts.first?.outcome, "applied", "the journal must record it applied")
    }

    // MARK: - 2. A destructive action is staged — never run, never claimed

    func testDestructiveActionStagesWithoutRunningOrClaiming() async throws {
        let (service, core, executor) = try makeService()

        let response = try await service.respond(prompt: "empty the trash", actor: .user)

        // Reported as staged — NOT performed.
        guard case .staged = response.kind else {
            return XCTFail("expected .staged, got \(response.kind)")
        }
        // The proposal is parked for one-click Accept …
        XCTAssertEqual(try core.staged.list(state: "staged").count, 1)
        // … the machine was never touched: zero executor effects, nothing trashed …
        XCTAssertTrue(
            executor.calls.isEmpty,
            "a staged action must drive no executor effect: \(executor.calls)"
        )
        XCTAssertTrue(executor.trashedPaths.isEmpty, "the trash must not be emptied by staging")
        // … and no `command.run` effect was journaled applied for the destructive effect.
        let appliedEffects = try core.journal.allEntries().filter {
            $0.action.name == "command.run" && $0.outcome == "applied"
        }
        XCTAssertTrue(
            appliedEffects.isEmpty,
            "a staged destructive effect must never be journaled applied"
        )
    }

    // MARK: - 3. No over-claim when the harness structurally cannot perform

    /// With no core wired, a safe action cannot be carried out. The harness must say
    /// so honestly — it must never fabricate "Volume set to 30%." for a set-volume
    /// that never ran. (set-volume is not destructive, so it reaches the
    /// can't-perform guard, never the machine.)
    func testHarnessDoesNotClaimAnActionItCannotPerform() async throws {
        let service = SummonAIService(ladder: .testing(fake: FakeModelRung(cannedText: Self.liar)))

        let response = try await service.respond(prompt: "set the volume to 30", actor: .user)

        guard case let .answer(text) = response.kind else {
            return XCTFail("expected an honest .answer, got \(response.kind)")
        }
        XCTAssertFalse(text.contains("Volume set"), "must not claim a set-volume that never ran")
        XCTAssertFalse(text.contains(Self.liar), "must not surface the model's success claim")
    }

    // MARK: - 4. Failure is honest — a rejected dispatch is recorded as rejected

    /// The correspondence backbone. A dispatch the bus rejects is recorded as
    /// `rejected:` in the journal — never `applied`. So the persistent record can
    /// never over-claim a failure as a success. An empty settings key is a
    /// machine-safe store rejection (no external effect).
    func testRejectedDispatchIsRecordedAsRejectedNeverApplied() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])

        let result = try core.dispatch(action: .settingsSet(key: "", value: .string("x")), actor: .user)

        guard case let .rejected(reason) = result.outcome else {
            return XCTFail("expected .rejected, got \(result.outcome)")
        }
        XCTAssertFalse(reason.isEmpty, "a rejection must carry a reason")
        let entry = try XCTUnwrap(core.journal.entry(id: result.envelopeID))
        XCTAssertTrue(
            entry.outcome.hasPrefix("rejected:"),
            "the journal must record the real outcome, got: \(entry.outcome)"
        )
    }

    // MARK: - 5. The success text is derived from the typed action, not the model

    /// `.performed`'s text comes from the typed `CoreAction` that was applied — a
    /// deterministic past-tense summary — so it cannot drift from what actually ran.
    func testPerformedSummaryIsDerivedFromTheTypedActionNotTheModel() throws {
        let setVolume = try XCTUnwrap(SummonActionParser.parse("set the volume to 30"))
        XCTAssertEqual(SummonAIService.performedSummary(setVolume), "Volume set to 30%.")

        let snippet = try XCTUnwrap(SummonActionParser.parse("make a snippet called sig that says hi"))
        XCTAssertTrue(
            SummonAIService.performedSummary(snippet).contains("sig"),
            "the summary must name the snippet that was saved"
        )
    }

    // MARK: - 6. The model answers questions but is never the actor

    /// A question routes to the model (its text appears). The same rigged model,
    /// asked to ACT, never has its claim surface — the two paths are disjoint, which
    /// is what makes "the model never claims an action" hold.
    func testModelTextAppearsForQuestionsButNeverForActions() async throws {
        let (service, _, _) = try makeService()

        let question = try await service.respond(prompt: "a plain question about history", actor: .user)
        guard case let .answer(qText) = question.kind else {
            return XCTFail("expected an .answer for a question, got \(question.kind)")
        }
        XCTAssertTrue(qText.contains(Self.liar), "a question is answered by the model")

        let action = try await service.respond(
            prompt: "make a snippet called sig that says hi", actor: .user
        )
        guard case let .performed(aText) = action.kind else {
            return XCTFail("expected .performed for an action, got \(action.kind)")
        }
        XCTAssertFalse(aText.contains(Self.liar), "an action's report never comes from the model")
    }
}
