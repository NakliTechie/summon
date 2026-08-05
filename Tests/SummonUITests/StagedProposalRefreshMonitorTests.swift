import XCTest
@testable import SummonCore
@testable import SummonUI

final class StagedProposalRefreshMonitorTests: XCTestCase {
    func testNotificationRefreshesVisibleProposalSurface() throws {
        let core = try SummonCore.inMemory()
        let refreshed = expectation(description: "notification refresh")
        let monitor = StagedProposalRefreshMonitor { refreshed.fulfill() }
        _ = monitor

        _ = try core.dispatch(
            action: .settingsSet(key: "agent.socket.enabled", value: .bool(true)),
            actor: .agent
        )
        wait(for: [refreshed], timeout: 1)
    }

    func testPollingFindsProposalInsertedAfterSurfaceOpens() throws {
        let core = try SummonCore.inMemory()
        let proposal = PersistedStagedProposal(
            id: "late-proposal",
            rung: "agent",
            prompt: "late",
            output: #"{"name":"agent.version"}"#
        )
        let refreshed = expectation(description: "poll refresh")
        var observed = false
        let monitor = StagedProposalRefreshMonitor(interval: 0.02) {
            guard !observed, (try? core.staged.get(proposal.id)) != nil else { return }
            observed = true
            refreshed.fulfill()
        }
        monitor.startPolling()
        defer { monitor.stopPolling() }
        try core.staged.upsert(proposal)
        wait(for: [refreshed], timeout: 1)
    }

    func testIncomingProposalDoesNotReplaceEditedCurrentReview() throws {
        let core = try SummonCore.inMemory()
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        try core.staged.upsert(PersistedStagedProposal(
            id: firstID,
            createdAt: Date(timeIntervalSince1970: 1),
            rung: "L0",
            prompt: "first",
            output: "first original"
        ))
        let controller = LauncherPanelController(core: core, stagedTextWriter: { _ in })
        controller.refreshStagedStrip()
        controller.stagedReviewView.reviewedText = "first edited"

        try core.staged.upsert(PersistedStagedProposal(
            id: secondID,
            createdAt: Date(timeIntervalSince1970: 2),
            rung: "L0",
            prompt: "second",
            output: "second original"
        ))
        controller.refreshStagedStrip()

        XCTAssertEqual(controller.stagedID, firstID)
        XCTAssertEqual(controller.stagedReviewView.reviewedText, "first edited")

        controller.rejectStaged()

        XCTAssertEqual(controller.stagedID, secondID)
        XCTAssertEqual(controller.stagedReviewView.reviewedText, "second original")
    }

    func testPasteboardFailureLeavesTextProposalStaged() throws {
        let core = try SummonCore.inMemory()
        let proposalID = UUID().uuidString
        try core.staged.upsert(PersistedStagedProposal(
            id: proposalID,
            rung: "L0",
            prompt: "copy",
            output: "reviewed output"
        ))
        let controller = LauncherPanelController(
            core: core,
            stagedTextWriter: { _ in throw CoreError.io("fixture pasteboard rejection") }
        )
        controller.refreshStagedStrip()

        controller.acceptStaged()

        XCTAssertEqual(try core.staged.get(proposalID)?.state, "staged")
        XCTAssertTrue(controller.footerError?.contains("fixture pasteboard rejection") == true)
    }
}
