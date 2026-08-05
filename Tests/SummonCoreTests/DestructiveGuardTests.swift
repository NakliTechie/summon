import XCTest
@testable import SummonCore

final class DestructiveGuardTests: XCTestCase {
    func testClipboardClearUnpinnedIsDestructive() {
        XCTAssertTrue(DestructiveGuard.isDestructive(.clipboardClearUnpinned))
        XCTAssertTrue(
            DestructiveGuard.requiresUserApproval(actor: .agent, action: .clipboardClearUnpinned)
        )
        XCTAssertFalse(
            DestructiveGuard.requiresUserApproval(actor: .user, action: .clipboardClearUnpinned)
        )
    }

    func testExtActorGatedLikeAgent() {
        let action = CoreAction.snippetDelete(id: "s1")
        XCTAssertTrue(DestructiveGuard.requiresUserApproval(actor: .ext(id: "x"), action: action))
        XCTAssertTrue(DestructiveGuard.requiresUserApproval(actor: .agent, action: action))
        XCTAssertFalse(DestructiveGuard.requiresUserApproval(actor: .user, action: action))
        XCTAssertFalse(DestructiveGuard.requiresUserApproval(actor: .system, action: action))
    }

    func testSystemEmptyTrashIsDestructiveForAgent() {
        let action = CoreAction.moduleRun(
            name: "command.run",
            targetID: "sys:empty",
            path: "summon://system/empty-trash",
            payload: [:]
        )
        XCTAssertTrue(DestructiveGuard.isDestructive(action))
        XCTAssertTrue(DestructiveGuard.requiresUserApproval(actor: .agent, action: action))
    }

    func testRestrictedSettings() {
        let set = CoreAction.settingsSet(key: "web.search.enabled", value: .bool(true))
        XCTAssertTrue(DestructiveGuard.requiresUserApproval(actor: .agent, action: set))
        let login = CoreAction.settingsSet(key: "launchAtLogin", value: .bool(true))
        XCTAssertTrue(DestructiveGuard.requiresUserApproval(actor: .agent, action: login))
        let free = CoreAction.settingsSet(key: "theme.appearance", value: .string("dark"))
        XCTAssertFalse(DestructiveGuard.requiresUserApproval(actor: .agent, action: free))
    }

    func testIgnoreAndWebConfigurationStageForAgent() {
        for action in [
            CoreAction.clipboardIgnoreAdd(entry: "com.example.Secret"),
            .clipboardIgnoreRemove(entry: "com.example.Secret"),
            .webConfigSet(enabled: true, baseURL: "http://127.0.0.1:8080"),
        ] {
            XCTAssertTrue(DestructiveGuard.requiresUserApproval(actor: .agent, action: action))
            XCTAssertTrue(
                DestructiveGuard.requiresUserApproval(actor: .ext(id: "probe"), action: action)
            )
        }
    }

    func testExtensionAuthorityChangesStageBeforeExecutor() throws {
        let executor = RecordingModuleExecutor()
        let core = try SummonCore.inMemory(executor: executor)
        for action in [
            CoreAction.extensionInstall(sourcePath: "/tmp/example-extension"),
            .extensionGrant(extensionID: "example", entitlement: "network", granted: true),
        ] {
            let result = try core.dispatch(action: action, actor: .agent)
            XCTAssertTrue(result.isStaged)
        }
        XCTAssertTrue(executor.calls.isEmpty)
    }

    func testAgentClearUnpinnedStagesAndUserAcceptApplies() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "a",
                text: "one",
                sourceApp: nil,
                createdAt: Date(),
                pinned: false
            ),
            actor: .user
        )
        let stagedResult = try core.dispatch(action: .clipboardClearUnpinned, actor: .agent)
        XCTAssertTrue(stagedResult.isStaged)
        XCTAssertFalse(stagedResult.isApplied)
        XCTAssertEqual(try core.clipboard.all().count, 1)

        guard let pid = stagedResult.stagedProposalID else {
            return XCTFail("expected proposal id")
        }
        let output = try XCTUnwrap(try core.staged.get(pid)?.output)
        let applied = try core.acceptStagedAgentAction(
            id: pid,
            reviewedOutput: output,
            actor: .user
        )
        XCTAssertTrue(applied.isApplied)
        XCTAssertEqual(try core.clipboard.all().count, 0)
    }

    func testAgentDeleteStagesNotRejectsWithoutStore() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "x",
                text: "t",
                sourceApp: nil,
                createdAt: Date(),
                pinned: false
            ),
            actor: .user
        )
        let r = try core.dispatch(action: .clipboardDelete(id: "x"), actor: .agent)
        XCTAssertTrue(r.isStaged)
        XCTAssertNotNil(try core.clipboard.get(id: "x"))
        if let pid = r.stagedProposalID {
            let output = try XCTUnwrap(try core.staged.get(pid)?.output)
            _ = try core.acceptStagedAgentAction(
                id: pid,
                reviewedOutput: output,
                actor: .user
            )
        }
        XCTAssertNil(try core.clipboard.get(id: "x"))
    }

    func testExhaustiveDestructiveCases() {
        let cases: [CoreAction] = [
            .clipboardDelete(id: "1"),
            .snippetDelete(id: "1"),
            .quicklinkDelete(id: "1"),
            .clipboardClearUnpinned,
            .moduleRun(name: "file.trash", targetID: "f", path: "/tmp/x", payload: [:]),
            .moduleRun(name: "process.kill", targetID: "p", path: nil, payload: ["destructive": .bool(true)]),
            .moduleRun(
                name: "command.run",
                targetID: "s",
                path: "summon://system/lock",
                payload: [:]
            ),
        ]
        for action in cases {
            XCTAssertTrue(
                DestructiveGuard.isDestructive(action) || DestructiveGuard.requiresUserApproval(
                    actor: .agent,
                    action: action
                ),
                "expected elevated: \(action.name)"
            )
        }
    }

    func testEveryModuleEffectStagesForAgentAndExtension() {
        let names = [
            "app.open",
            "file.reveal",
            "clipboard.copy",
            "snippet.copy",
            "screenshot.full",
            "terminal.run",
            "speech.speak",
            "command.run",
        ]
        for name in names {
            let action = CoreAction.moduleRun(
                name: name,
                targetID: "probe",
                path: "/tmp/probe",
                payload: [:]
            )
            XCTAssertTrue(DestructiveGuard.requiresUserApproval(actor: .agent, action: action))
            XCTAssertTrue(
                DestructiveGuard.requiresUserApproval(actor: .ext(id: "probe"), action: action)
            )
            XCTAssertFalse(DestructiveGuard.requiresUserApproval(actor: .user, action: action))
            XCTAssertFalse(DestructiveGuard.requiresUserApproval(actor: .system, action: action))
        }
    }

    func testAgentModuleRunStagesBeforeExecutor() throws {
        let executor = RecordingModuleExecutor()
        let core = try SummonCore.inMemory(executor: executor)
        let result = SearchResult(
            id: "app:/Applications/Test.app",
            title: "Test",
            kind: .app,
            path: "/Applications/Test.app"
        )
        let outcome = try core.invoke(actionName: "app.open", result: result, actor: .agent)
        XCTAssertTrue(outcome.isStaged)
        XCTAssertTrue(executor.calls.isEmpty)
    }

    func testConcurrentAcceptHasOneWinner() throws {
        let core = try SummonCore.inMemory()
        let staged = try core.dispatch(
            action: .settingsSet(key: "agent.socket.enabled", value: .bool(true)),
            actor: .agent
        )
        let proposalID = try XCTUnwrap(staged.stagedProposalID)
        let output = try XCTUnwrap(try core.staged.get(proposalID)?.output)
        let outcomes = ConcurrentAcceptOutcomes()

        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do {
                let result = try core.acceptStagedAgentAction(
                    id: proposalID,
                    reviewedOutput: output,
                    actor: .user
                )
                outcomes.recordApplied(result.isApplied)
            } catch {
                outcomes.recordError()
            }
        }

        XCTAssertEqual(outcomes.appliedCount, 1)
        XCTAssertEqual(outcomes.errorCount, 1)
        XCTAssertEqual(try core.staged.get(proposalID)?.state, "accepted")
        XCTAssertEqual(try core.settings.get("agent.socket.enabled"), .bool(true))
        let accepts = try core.journal.allEntries().filter {
            $0.actor == .user && $0.action.name == "settings.set"
        }
        XCTAssertEqual(accepts.count, 1)
    }

    func testAcceptRecordsApplyFailureDistinctly() throws {
        let core = try SummonCore.inMemory()
        let action = CoreAction.snippetUpsert(id: "invalid", name: "", body: "body", keyword: nil)
        let output = String(data: try JSONEncoder().encode(action), encoding: .utf8)!
        let proposal = PersistedStagedProposal(
            rung: "agent",
            prompt: "invalid snippet",
            output: output
        )
        try core.staged.upsert(proposal)

        let result = try core.acceptStagedAgentAction(
            id: proposal.id,
            reviewedOutput: output,
            actor: .user
        )
        XCTAssertFalse(result.isApplied)
        XCTAssertEqual(try core.staged.get(proposal.id)?.state, "apply_failed")
        XCTAssertNotNil(try core.staged.get(proposal.id)?.failureReason)
    }

    func testAgentCannotAcceptItsOwnStagedAction() throws {
        let core = try SummonCore.inMemory()
        let staged = try core.dispatch(
            action: .settingsSet(key: "agent.socket.enabled", value: .bool(true)),
            actor: .agent
        )
        let proposalID = try XCTUnwrap(staged.stagedProposalID)
        let output = try XCTUnwrap(try core.staged.get(proposalID)?.output)

        XCTAssertThrowsError(
            try core.acceptStagedAgentAction(
                id: proposalID,
                reviewedOutput: output,
                actor: .agent
            )
        )
        XCTAssertEqual(try core.staged.get(proposalID)?.state, "staged")
        XCTAssertNil(try core.settings.get("agent.socket.enabled"))
    }

    func testReviewedEditIsTheActionThatExecutes() throws {
        let core = try SummonCore.inMemory()
        let staged = try core.dispatch(
            action: .settingsSet(key: "agent.socket.enabled", value: .bool(true)),
            actor: .agent
        )
        let proposalID = try XCTUnwrap(staged.stagedProposalID)
        let edited = try SchemaGate().reviewedText(
            for: .settingsSet(key: "agent.socket.enabled", value: .bool(false))
        )

        let result = try core.acceptStagedAgentAction(
            id: proposalID,
            reviewedOutput: edited,
            actor: .user
        )
        XCTAssertTrue(result.isApplied)
        XCTAssertEqual(try core.settings.get("agent.socket.enabled"), .bool(false))
        XCTAssertEqual(try core.staged.get(proposalID)?.output, edited)
    }

    func testInvalidReviewedEditLeavesProposalStaged() throws {
        let core = try SummonCore.inMemory()
        let staged = try core.dispatch(
            action: .settingsSet(key: "agent.socket.enabled", value: .bool(true)),
            actor: .agent
        )
        let proposalID = try XCTUnwrap(staged.stagedProposalID)
        let edited = #"{"name":"settings.set","key":"agent.socket.enabled","value":true,"extra":1}"#

        XCTAssertThrowsError(
            try core.acceptStagedAgentAction(
                id: proposalID,
                reviewedOutput: edited,
                actor: .user
            )
        )
        XCTAssertEqual(try core.staged.get(proposalID)?.state, "staged")
        XCTAssertNil(try core.settings.get("agent.socket.enabled"))
    }

    func testStagedWebConfigDoesNotChangeRuntimeConfigUntilUserAccepts() throws {
        let core = try SummonCore.inMemory()
        core.webConfig.enableWithLocalhostPreset()
        let staged = try core.persistWebConfig(actor: .agent)
        XCTAssertTrue(staged.isStaged)
        XCTAssertFalse(core.webConfig.enabled)
        XCTAssertNil(try core.settings.get("web.search.enabled"))

        let proposalID = try XCTUnwrap(staged.stagedProposalID)
        let output = try XCTUnwrap(try core.staged.get(proposalID)?.output)
        let accepted = try core.acceptStagedAgentAction(
            id: proposalID,
            reviewedOutput: output,
            actor: .user
        )
        XCTAssertTrue(accepted.isApplied)
        XCTAssertTrue(core.webConfig.enabled)
        XCTAssertEqual(core.webConfig.baseURL, WebSearchConfig.localhostPreset)
    }

    func testProposalDecisionsCarryUserJournalAttribution() throws {
        let core = try SummonCore.inMemory()
        let acceptedStage = try core.dispatch(
            action: .settingsSet(key: "agent.socket.enabled", value: .bool(true)),
            actor: .agent
        )
        let acceptedID = try XCTUnwrap(acceptedStage.stagedProposalID)
        let acceptedOutput = try XCTUnwrap(try core.staged.get(acceptedID)?.output)
        _ = try core.acceptStagedAgentAction(
            id: acceptedID,
            reviewedOutput: acceptedOutput,
            actor: .user
        )

        let rejectedStage = try core.dispatch(action: .clipboardClearUnpinned, actor: .agent)
        let rejectedID = try XCTUnwrap(rejectedStage.stagedProposalID)
        try core.rejectStagedAgentAction(id: rejectedID, actor: .user)

        let invalid = CoreAction.snippetUpsert(
            id: "invalid",
            name: "",
            body: "body",
            keyword: nil
        )
        let invalidOutput = String(data: try JSONEncoder().encode(invalid), encoding: .utf8)!
        let failed = PersistedStagedProposal(rung: "agent", prompt: "invalid", output: invalidOutput)
        try core.staged.upsert(failed)
        _ = try core.acceptStagedAgentAction(
            id: failed.id,
            reviewedOutput: invalidOutput,
            actor: .user
        )

        let decisions = try core.journal.allEntries().compactMap { entry -> (ActorTag, String)? in
            guard case .proposalDecision(_, let state, _) = entry.action else { return nil }
            return (entry.actor, state)
        }
        XCTAssertEqual(decisions.map(\.0), [.user, .user, .user])
        XCTAssertEqual(decisions.map(\.1), ["accepted", "rejected", "apply_failed"])
        XCTAssertThrowsError(try core.rejectStagedAgentAction(id: acceptedID, actor: .agent))

        let replayed = try core.replayedCopy()
        XCTAssertEqual(try replayed.settings.get("agent.socket.enabled"), .bool(true))
    }

    func testStagingPublishesChangeNotification() throws {
        let core = try SummonCore.inMemory()
        let changed = expectation(description: "staged proposal changed")
        let token = NotificationCenter.default.addObserver(
            forName: .summonStagedProposalDidChange,
            object: nil,
            queue: nil
        ) { _ in
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = try core.dispatch(
            action: .settingsSet(key: "agent.socket.enabled", value: .bool(true)),
            actor: .agent
        )
        wait(for: [changed], timeout: 1)
    }
}

private final class ConcurrentAcceptOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var appliedCount = 0
    private(set) var errorCount = 0

    func recordApplied(_ applied: Bool) {
        lock.lock()
        if applied { appliedCount += 1 }
        lock.unlock()
    }

    func recordError() {
        lock.lock()
        errorCount += 1
        lock.unlock()
    }
}
