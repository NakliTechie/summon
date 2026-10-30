import GRDB
import XCTest
@testable import SummonCore

/// Rung names became readable on 2026-10-30 (`L0`/`L1`/`L2` → `mlx`/`apple-fm`/
/// `local-server`). A store written by an older build must read back renamed.
final class StagedProposalRungMigrationTests: XCTestCase {
    func testMigrateRewritesLegacyRungNamesAndLeavesOthersAlone() throws {
        let store = StagedProposalStore(dbQueue: try DatabaseQueue())
        try store.migrate()
        let legacy = ["L0", "L1", "L2", "agent", "smartpaste"]
        var ids: [String: String] = [:]
        for rung in legacy {
            let proposal = PersistedStagedProposal(rung: rung, prompt: "p", output: "o")
            try store.upsert(proposal)
            ids[rung] = proposal.id
        }

        // The next launch runs migrate() again over the old rows.
        try store.migrate()

        let expected = [
            "L0": "mlx", "L1": "apple-fm", "L2": "local-server",
            "agent": "agent", "smartpaste": "smartpaste",
        ]
        for (old, new) in expected {
            let id = try XCTUnwrap(ids[old])
            XCTAssertEqual(try store.get(id)?.rung, new, "stored \(old)")
        }

        // Safe to repeat: a third run changes nothing.
        try store.migrate()
        XCTAssertEqual(try store.get(try XCTUnwrap(ids["L1"]))?.rung, "apple-fm")
    }
}
