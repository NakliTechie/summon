import Foundation
import GRDB

public extension Notification.Name {
    static let summonStagedProposalDidChange = Notification.Name(
        "SummonCore.stagedProposalDidChange"
    )
}

/// Persist staged AI proposals (accept/reject survives restarts).
public struct PersistedStagedProposal: Sendable, Hashable, Codable, Equatable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let rung: String
    public let prompt: String
    public let output: String
    public let egressSummary: String
    public var state: String // staged | applying | accepted | rejected | apply_failed | expired
    public var failureReason: String?

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        rung: String,
        prompt: String,
        output: String,
        egressSummary: String = "",
        state: String = "staged",
        failureReason: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rung = rung
        self.prompt = prompt
        self.output = output
        self.egressSummary = egressSummary
        self.state = state
        self.failureReason = failureReason
    }
}

public struct StagedProposalRecoveryResult: Sendable, Hashable, Equatable {
    public let resetToStaged: Int
    public let accepted: Int
    public let failed: Int

    public var total: Int { resetToStaged + accepted + failed }
}

public struct StagedProposalStore: Sendable {
    public static let defaultStagedLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let maximumActiveProposals = 100
    public static let maximumRetainedTerminalProposals = 1_000
    public static let maximumPromptBytes = 256 * 1_024
    public static let maximumOutputBytes = 4 * 1_024 * 1_024
    public static let maximumEgressSummaryBytes = 64 * 1_024
    public static let maximumFailureReasonBytes = 64 * 1_024
    private let dbQueue: DatabaseQueue
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS staged_proposals (
                    id TEXT PRIMARY KEY NOT NULL,
                    created_at TEXT NOT NULL,
                    rung TEXT NOT NULL,
                    prompt TEXT NOT NULL,
                    output TEXT NOT NULL,
                    egress TEXT NOT NULL,
                    state TEXT NOT NULL,
                    failure_reason TEXT
                );
                """)
            let columns = try Set(db.columns(in: "staged_proposals").map(\.name))
            if !columns.contains("failure_reason") {
                try db.execute(sql: "ALTER TABLE staged_proposals ADD COLUMN failure_reason TEXT")
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS staged_proposals_state_created_idx
                ON staged_proposals(state, created_at)
                """)
        }
    }

    /// Expires proposals that were never reviewed within the bounded lifetime.
    @discardableResult
    public func expireStale(
        now: Date = Date(),
        lifetime: TimeInterval = Self.defaultStagedLifetime
    ) throws -> Int {
        try dbQueue.write { db in
            let expired = try expireStale(now: now, lifetime: lifetime, in: db)
            _ = try enforceRetentionBounds(in: db)
            return expired
        }
    }

    @discardableResult
    func expireStale(
        now: Date,
        lifetime: TimeInterval,
        in db: Database
    ) throws -> Int {
        guard lifetime >= 0 else { throw CoreError.store("proposal lifetime must be non-negative") }
        let cutoff = Self.iso.string(from: now.addingTimeInterval(-lifetime))
        try db.execute(
            sql: """
                UPDATE staged_proposals
                SET state = 'expired', failure_reason = 'review window expired'
                WHERE state = 'staged' AND created_at < ?
                """,
            arguments: [cutoff]
        )
        return db.changesCount
    }

    public func upsert(_ p: PersistedStagedProposal) throws {
        try dbQueue.write { db in
            try upsert(p, in: db)
        }
    }

    func upsert(_ proposal: PersistedStagedProposal, in db: Database) throws {
        try Self.validate(proposal)
        try db.execute(
            sql: """
                INSERT INTO staged_proposals (
                  id, created_at, rung, prompt, output, egress, state, failure_reason
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  state = excluded.state,
                  output = excluded.output,
                  failure_reason = excluded.failure_reason
                """,
            arguments: [
                proposal.id,
                Self.iso.string(from: proposal.createdAt),
                proposal.rung,
                proposal.prompt,
                proposal.output,
                proposal.egressSummary,
                proposal.state,
                proposal.failureReason,
            ]
        )
        _ = try enforceRetentionBounds(in: db)
    }

    @discardableResult
    func enforceRetentionBounds(
        maximumActive: Int = Self.maximumActiveProposals,
        maximumTerminal: Int = Self.maximumRetainedTerminalProposals
    ) throws -> (expired: Int, pruned: Int) {
        try dbQueue.write { db in
            try enforceRetentionBounds(
                maximumActive: maximumActive,
                maximumTerminal: maximumTerminal,
                in: db
            )
        }
    }

    @discardableResult
    private func enforceRetentionBounds(
        maximumActive: Int = Self.maximumActiveProposals,
        maximumTerminal: Int = Self.maximumRetainedTerminalProposals,
        in db: Database
    ) throws -> (expired: Int, pruned: Int) {
        guard maximumActive >= 0, maximumTerminal >= 0 else {
            throw CoreError.store("proposal retention limits must be non-negative")
        }
        try db.execute(
            sql: """
                UPDATE staged_proposals
                SET state = 'expired', failure_reason = 'active proposal limit exceeded'
                WHERE id IN (
                  SELECT id FROM staged_proposals
                  WHERE state = 'staged'
                  ORDER BY created_at DESC, id DESC
                  LIMIT -1 OFFSET ?
                )
                """,
            arguments: [maximumActive]
        )
        let expired = db.changesCount
        try db.execute(
            sql: """
                DELETE FROM staged_proposals
                WHERE id IN (
                  SELECT id FROM staged_proposals
                  WHERE state NOT IN ('staged', 'applying')
                  ORDER BY created_at DESC, id DESC
                  LIMIT -1 OFFSET ?
                )
                """,
            arguments: [maximumTerminal]
        )
        return (expired, db.changesCount)
    }

    public func get(_ id: String) throws -> PersistedStagedProposal? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM staged_proposals WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return try Self.from(row)
        }
    }

    public func delete(id: String) throws {
        try dbQueue.write { db in
            try delete(id: id, in: db)
        }
    }

    func delete(id: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM staged_proposals WHERE id = ?", arguments: [id])
    }

    public func list(state: String? = "staged") throws -> [PersistedStagedProposal] {
        try dbQueue.read { db in
            try list(state: state, in: db)
        }
    }

    func list(state: String?, in db: Database) throws -> [PersistedStagedProposal] {
        let rows: [Row]
        if let state {
            rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM staged_proposals WHERE state = ? ORDER BY created_at DESC",
                arguments: [state]
            )
        } else {
            rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM staged_proposals ORDER BY created_at DESC"
            )
        }
        return try rows.map { try Self.from($0) }
    }

    public func setState(id: String, state: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE staged_proposals SET state = ?, failure_reason = NULL WHERE id = ?",
                arguments: [state, id]
            )
        }
    }

    /// Claims one staged proposal for application. The conditional update admits one caller.
    public func claimForApply(
        id: String,
        rung: String,
        reviewedOutput: String
    ) throws -> PersistedStagedProposal? {
        try Self.validateText(
            "reviewed proposal output",
            reviewedOutput,
            maximumBytes: Self.maximumOutputBytes
        )
        return try dbQueue.write { db -> PersistedStagedProposal? in
            _ = try expireStale(
                now: Date(),
                lifetime: Self.defaultStagedLifetime,
                in: db
            )
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM staged_proposals WHERE id = ? AND rung = ? AND state = 'staged'",
                arguments: [id, rung]
            ) else { return nil }
            try db.execute(
                sql: """
                    UPDATE staged_proposals
                    SET state = 'applying', output = ?, failure_reason = NULL
                    WHERE id = ? AND rung = ? AND state = 'staged'
                    """,
                arguments: [reviewedOutput, id, rung]
            )
            guard db.changesCount == 1 else { return nil }
            let proposal = try Self.from(row)
            return PersistedStagedProposal(
                id: proposal.id,
                createdAt: proposal.createdAt,
                rung: proposal.rung,
                prompt: proposal.prompt,
                output: reviewedOutput,
                egressSummary: proposal.egressSummary,
                state: "applying"
            )
        }
    }

    /// Performs one named state transition and reports whether the expected state matched.
    @discardableResult
    public func transition(
        id: String,
        from expectedState: String,
        to newState: String,
        failureReason: String? = nil,
        reviewedOutput: String? = nil
    ) throws -> Bool {
        try dbQueue.write { db in
            try transition(
                id: id,
                from: expectedState,
                to: newState,
                failureReason: failureReason,
                reviewedOutput: reviewedOutput,
                in: db
            )
        }
    }

    @discardableResult
    func transition(
        id: String,
        from expectedState: String,
        to newState: String,
        failureReason: String? = nil,
        reviewedOutput: String? = nil,
        in db: Database
    ) throws -> Bool {
        if let failureReason {
            try Self.validateText(
                "proposal failure reason",
                failureReason,
                maximumBytes: Self.maximumFailureReasonBytes
            )
        }
        if let reviewedOutput {
            try Self.validateText(
                "reviewed proposal output",
                reviewedOutput,
                maximumBytes: Self.maximumOutputBytes
            )
        }
        try db.execute(
            sql: """
                UPDATE staged_proposals
                SET state = ?, failure_reason = ?, output = COALESCE(?, output)
                WHERE id = ? AND state = ?
                """,
            arguments: [newState, failureReason, reviewedOutput, id, expectedState]
        )
        return db.changesCount == 1
    }

    /// Reconciles proposals claimed before a process interruption against their durable action row.
    public func reconcileApplying(journal: ActionJournal) throws -> StagedProposalRecoveryResult {
        try dbQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id FROM staged_proposals WHERE state = 'applying' ORDER BY created_at"
            )
            var reset = 0
            var accepted = 0
            var failed = 0
            for row in rows {
                let proposalID: String = row["id"]
                guard let actionID = UUID(uuidString: proposalID) else {
                    if try transition(
                        id: proposalID,
                        from: "applying",
                        to: "apply_failed",
                        failureReason: "proposal id cannot identify the accepted action",
                        in: db
                    ) {
                        failed += 1
                    }
                    continue
                }
                guard let label = try journal.outcomeLabel(envelopeID: actionID, in: db) else {
                    if try transition(
                        id: proposalID,
                        from: "applying",
                        to: "staged",
                        in: db
                    ) {
                        reset += 1
                    }
                    continue
                }
                let state: String
                let reason: String?
                if label == "applied" {
                    state = "accepted"
                    reason = "recovered after interrupted acceptance"
                    accepted += 1
                } else if label == "intent" {
                    state = "apply_failed"
                    reason = "effect outcome unresolved after interruption; effect was not repeated"
                    failed += 1
                } else if case .rejected(let rejection) = ActionJournal.outcome(from: label) {
                    state = "apply_failed"
                    reason = String(rejection.prefix(1_024))
                    failed += 1
                } else {
                    state = "apply_failed"
                    reason = "accepted action has an invalid journal outcome"
                    failed += 1
                }
                guard try transition(
                    id: proposalID,
                    from: "applying",
                    to: state,
                    failureReason: state == "accepted" ? nil : reason,
                    in: db
                ) else { continue }
                let decision = ActionEnvelope(
                    actor: .system,
                    action: .proposalDecision(id: proposalID, state: state, reason: reason)
                )
                try journal.append(envelope: decision, outcome: .applied, in: db)
            }
            return StagedProposalRecoveryResult(
                resetToStaged: reset,
                accepted: accepted,
                failed: failed
            )
        }
    }

    private static func from(_ row: Row) throws -> PersistedStagedProposal {
        let ts: String = row["created_at"]
        guard let date = iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) else {
            let id: String = row["id"]
            throw CoreError.store("staged proposal \(id) has an invalid created_at")
        }
        return PersistedStagedProposal(
            id: row["id"],
            createdAt: date,
            rung: row["rung"],
            prompt: row["prompt"],
            output: row["output"],
            egressSummary: row["egress"],
            state: row["state"],
            failureReason: row["failure_reason"]
        )
    }

    private static func validate(_ proposal: PersistedStagedProposal) throws {
        try validateText("proposal prompt", proposal.prompt, maximumBytes: maximumPromptBytes)
        try validateText("proposal output", proposal.output, maximumBytes: maximumOutputBytes)
        try validateText(
            "proposal egress summary",
            proposal.egressSummary,
            maximumBytes: maximumEgressSummaryBytes
        )
        if let failureReason = proposal.failureReason {
            try validateText(
                "proposal failure reason",
                failureReason,
                maximumBytes: maximumFailureReasonBytes
            )
        }
    }

    private static func validateText(
        _ label: String,
        _ value: String,
        maximumBytes: Int
    ) throws {
        guard value.utf8.count <= maximumBytes else {
            throw CoreError.store("\(label) exceeds \(maximumBytes) UTF-8 bytes")
        }
    }
}
