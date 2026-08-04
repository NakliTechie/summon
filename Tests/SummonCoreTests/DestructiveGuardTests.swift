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
        let free = CoreAction.settingsSet(key: "theme.appearance", value: .string("dark"))
        XCTAssertFalse(DestructiveGuard.requiresUserApproval(actor: .agent, action: free))
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
        let applied = try core.acceptStagedAgentAction(id: pid)
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
            _ = try core.acceptStagedAgentAction(id: pid)
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
}
