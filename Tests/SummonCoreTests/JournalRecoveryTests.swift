import GRDB
import XCTest
@testable import SummonCore

final class JournalRecoveryTests: XCTestCase {
    func testStartupSurfacesUnresolvedEffectIntentWithoutPayload() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-orphan-intent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let first = try SummonCore(containerURL: container)
        let action = CoreAction.moduleRun(
            name: "app.open",
            targetID: "app:private-target",
            path: "/private/secret.app",
            payload: ["secret": .string("must-not-surface")]
        )
        let actionJSON = String(data: try JSONEncoder().encode(action), encoding: .utf8)!
        try first.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO action_journal (id, actor, timestamp, action_json, outcome)
                    VALUES (?, 'user', '2026-08-05T00:00:00Z', ?, 'intent')
                    """,
                arguments: [UUID().uuidString, actionJSON]
            )
        }

        let reopened = try SummonCore(containerURL: container)
        let warning = try XCTUnwrap(
            reopened.startupWarnings.first { $0.contains("outcome unresolved") }
        )

        XCTAssertTrue(warning.contains("module.run"))
        XCTAssertFalse(warning.contains("must-not-surface"))
        XCTAssertFalse(warning.contains("secret.app"))
    }

    func testReadAllSkipsAndReportsCorruptRows() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .settingsSet(key: "theme.appearance", value: .string("dark")),
            actor: .user
        )
        try core.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO action_journal (id, actor, timestamp, action_json, outcome)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    "user",
                    "2026-08-05T00:00:00Z",
                    #"{"name":"unknown.action"}"#,
                    "applied",
                ]
            )
        }

        let read = try core.journal.readAll()
        XCTAssertEqual(read.entries.count, 1)
        XCTAssertEqual(read.entries.first?.action.name, "settings.set")
        XCTAssertEqual(read.corruptions.count, 1)
        XCTAssertNotNil(read.corruptions.first?.seq)
        XCTAssertEqual(read.corruptions.first?.reason, "action_json failed schema decoding")
    }

    func testReadAllReportsClipboardActionWithMalformedTimestamp() throws {
        let core = try SummonCore.inMemory()
        try core.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO action_journal (id, actor, timestamp, action_json, outcome)
                    VALUES (?, 'user', '2026-08-05T00:00:00Z', ?, 'applied')
                    """,
                arguments: [
                    UUID().uuidString,
                    #"{"name":"clipboard.ingest","id":"clip","text":"body","createdAt":"invalid"}"#,
                ]
            )
        }

        let read = try core.journal.readAll()

        XCTAssertTrue(read.entries.isEmpty)
        XCTAssertEqual(read.corruptions.count, 1)
        XCTAssertEqual(read.corruptions[0].reason, "action_json failed schema decoding")
    }

    func testReadAllStopsAtExplicitMaterializationLimit() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .settingsSet(key: "first", value: .bool(true)),
            actor: .user
        )
        _ = try core.dispatch(
            action: .settingsSet(key: "second", value: .bool(true)),
            actor: .user
        )

        let read = try core.journal.readAll(maximumEntries: 1)

        XCTAssertEqual(read.entries.count, 1)
        XCTAssertTrue(read.didReachMaterializationLimit)
    }

    func testStartupSurfacesJournalCorruptionWithoutRawActionData() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-journal-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let first = try SummonCore(containerURL: container)
        try first.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO action_journal (id, actor, timestamp, action_json, outcome)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    "user",
                    "2026-08-05T00:00:00Z",
                    #"{"name":"unknown.action","secret":"must-not-surface"}"#,
                    "applied",
                ]
            )
        }

        let reopened = try SummonCore(containerURL: container)
        XCTAssertEqual(reopened.startupWarnings.count, 1)
        XCTAssertTrue(reopened.startupWarnings[0].contains("journal row"))
        XCTAssertFalse(reopened.startupWarnings[0].contains("must-not-surface"))
    }

    func testStaleProposalExpiresAndCannotBeClaimed() throws {
        let core = try SummonCore.inMemory()
        let old = PersistedStagedProposal(
            createdAt: Date(timeIntervalSince1970: 1),
            rung: "agent",
            prompt: "old",
            output: #"{"name":"agent.version"}"#
        )
        try core.staged.upsert(old)

        XCTAssertEqual(try core.staged.expireStale(now: Date()), 1)
        XCTAssertEqual(try core.staged.get(old.id)?.state, "expired")
        XCTAssertNil(try core.staged.claimForApply(
            id: old.id,
            rung: "agent",
            reviewedOutput: old.output
        ))
    }

    func testStagedProposalRetentionBoundsActiveAndTerminalRows() throws {
        let core = try SummonCore.inMemory()
        try core.staged.migrate()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<5 {
            try core.staged.upsert(PersistedStagedProposal(
                id: "proposal-\(index)",
                createdAt: base.addingTimeInterval(Double(index)),
                rung: "test",
                prompt: "prompt",
                output: "output"
            ))
        }

        let result = try core.staged.enforceRetentionBounds(
            maximumActive: 2,
            maximumTerminal: 1
        )

        XCTAssertEqual(result.expired, 3)
        XCTAssertEqual(result.pruned, 2)
        XCTAssertEqual(try core.staged.list(state: "staged").map(\.id), [
            "proposal-4", "proposal-3",
        ])
        XCTAssertEqual(try core.staged.list(state: nil).count, 3)
    }

    func testStagedProposalRejectsOversizedTextAtEveryWritePath() throws {
        let core = try SummonCore.inMemory()
        let oversizedPrompt = String(
            repeating: "p",
            count: StagedProposalStore.maximumPromptBytes + 1
        )
        XCTAssertThrowsError(try core.staged.upsert(PersistedStagedProposal(
            id: "oversized-prompt",
            rung: "test",
            prompt: oversizedPrompt,
            output: "output"
        )))

        let proposal = PersistedStagedProposal(
            id: "bounded-proposal",
            rung: "test",
            prompt: "prompt",
            output: "output"
        )
        try core.staged.upsert(proposal)
        let oversizedOutput = String(
            repeating: "o",
            count: StagedProposalStore.maximumOutputBytes + 1
        )
        XCTAssertThrowsError(try core.staged.claimForApply(
            id: proposal.id,
            rung: proposal.rung,
            reviewedOutput: oversizedOutput
        ))
        XCTAssertThrowsError(try core.staged.transition(
            id: proposal.id,
            from: "staged",
            to: "rejected",
            failureReason: String(
                repeating: "f",
                count: StagedProposalStore.maximumFailureReasonBytes + 1
            )
        ))
        XCTAssertEqual(try core.staged.get(proposal.id)?.state, "staged")
    }

    func testTextProposalDecisionsCommitStateOutputAndJournalTogether() throws {
        let core = try SummonCore.inMemory()
        let accepted = PersistedStagedProposal(
            id: "text-accept",
            rung: "fake",
            prompt: "accept",
            output: "draft"
        )
        let rejected = PersistedStagedProposal(
            id: "text-reject",
            rung: "fake",
            prompt: "reject",
            output: "discard"
        )
        try core.staged.upsert(accepted)
        try core.staged.upsert(rejected)

        try core.acceptStagedTextProposal(
            id: accepted.id,
            reviewedOutput: "reviewed",
            actor: .user
        )
        try core.rejectStagedProposal(id: rejected.id, actor: .user)

        XCTAssertEqual(try core.staged.get(accepted.id)?.state, "accepted")
        XCTAssertEqual(try core.staged.get(accepted.id)?.output, "reviewed")
        XCTAssertEqual(try core.staged.get(rejected.id)?.state, "rejected")
        let decisions = try core.journal.allEntries().compactMap { entry -> (String, String)? in
            guard entry.actor == .user,
                  case .proposalDecision(let id, let state, _) = entry.action else { return nil }
            return (id, state)
        }
        XCTAssertEqual(decisions.map(\.0), [accepted.id, rejected.id])
        XCTAssertEqual(decisions.map(\.1), ["accepted", "rejected"])
    }

    func testCorruptStagedTimestampIsReportedAndNotReplaced() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-staged-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let first = try SummonCore(containerURL: container)
        try first.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO staged_proposals (
                        id, created_at, rung, prompt, output, egress, state, failure_reason
                    ) VALUES ('corrupt-time', 'not-a-time', 'fake', 'p', 'o', '', 'staged', NULL)
                    """
            )
        }

        let reopened = try SummonCore(containerURL: container)
        let storedTimestamp = try reopened.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT created_at FROM staged_proposals WHERE id = 'corrupt-time'"
            )
        }

        XCTAssertEqual(storedTimestamp, "not-a-time")
        XCTAssertTrue(reopened.startupWarnings.contains { $0.contains("invalid created_at") })
        XCTAssertThrowsError(try reopened.staged.get("corrupt-time"))
    }

    func testInterruptedAcceptedProposalReconcilesFromDurableAction() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-proposal-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let first = try SummonCore(containerURL: container)
        let staged = try first.dispatch(
            action: .settingsSet(key: "agent.socket.enabled", value: .bool(true)),
            actor: .agent
        )
        let proposalID = try XCTUnwrap(staged.stagedProposalID)
        let output = try XCTUnwrap(try first.staged.get(proposalID)?.output)
        try first.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_proposal_decision
                BEFORE INSERT ON action_journal
                WHEN NEW.action_json LIKE '%proposal.decision%'
                BEGIN
                    SELECT RAISE(ABORT, 'injected proposal decision failure');
                END
                """)
        }

        XCTAssertThrowsError(try first.acceptStagedAgentAction(
            id: proposalID,
            reviewedOutput: output,
            actor: .user
        ))
        XCTAssertEqual(try first.settings.get("agent.socket.enabled"), .bool(true))
        XCTAssertEqual(try first.staged.get(proposalID)?.state, "applying")
        XCTAssertFalse(try first.journal.allEntries().contains {
            if case .proposalDecision = $0.action { return true }
            return false
        })

        try first.dbQueue.write { db in
            try db.execute(sql: "DROP TRIGGER fail_proposal_decision")
        }
        let reopened = try SummonCore(containerURL: container)
        XCTAssertEqual(try reopened.staged.get(proposalID)?.state, "accepted")
        XCTAssertTrue(reopened.startupWarnings.contains { $0.contains("accepted 1") })
        let recoveredDecisions = try reopened.journal.allEntries().filter {
            guard $0.actor == .system else { return false }
            if case .proposalDecision(let id, let state, _) = $0.action {
                return id == proposalID && state == "accepted"
            }
            return false
        }
        XCTAssertEqual(recoveredDecisions.count, 1)
    }

    func testInterruptedClaimWithoutActionReturnsToStaged() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-proposal-reset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let first = try SummonCore(containerURL: container)
        let proposal = PersistedStagedProposal(
            rung: "agent",
            prompt: "pending",
            output: #"{"name":"agent.version"}"#,
            state: "applying"
        )
        try first.staged.upsert(proposal)

        let reopened = try SummonCore(containerURL: container)
        XCTAssertEqual(try reopened.staged.get(proposal.id)?.state, "staged")
        XCTAssertTrue(reopened.startupWarnings.contains { $0.contains("reset 1") })
    }

    func testInterruptedEffectIntentBecomesFailureWithoutRepeat() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-proposal-intent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let first = try SummonCore(containerURL: container)
        let proposal = PersistedStagedProposal(
            rung: "agent",
            prompt: "effect",
            output: #"{"name":"module.run","module":"app.open","targetID":"app:x","payload":{}}"#,
            state: "applying"
        )
        try first.staged.upsert(proposal)
        let action = CoreAction.moduleRun(
            name: "app.open",
            targetID: "app:x",
            path: "/Applications/X.app",
            payload: [:]
        )
        let actionJSON = String(data: try JSONEncoder().encode(action), encoding: .utf8)!
        try first.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO action_journal (id, actor, timestamp, action_json, outcome)
                    VALUES (?, 'user', '2026-08-05T00:00:00Z', ?, 'intent')
                    """,
                arguments: [proposal.id, actionJSON]
            )
        }

        let reopened = try SummonCore(containerURL: container)
        XCTAssertEqual(try reopened.staged.get(proposal.id)?.state, "apply_failed")
        XCTAssertTrue(
            try XCTUnwrap(reopened.staged.get(proposal.id)?.failureReason)
                .contains("not repeated")
        )
        XCTAssertTrue(reopened.startupWarnings.contains { $0.contains("failed 1") })
    }
}
