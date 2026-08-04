import XCTest
@testable import SummonCore

/// C-spine gate: action journal replayed into a fresh core reconstructs store state byte-equal.
final class JournalReplayTests: XCTestCase {
    func testReplayByteEqual() throws {
        let original = try SummonCore.inMemory()

        let actions: [(ActorTag, CoreAction)] = [
            (.user, .settingsSet(key: "theme", value: .string("dark"))),
            (.agent, .settingsSet(key: "feature.agent_ui", value: .bool(false))),
            (.system, .settingsSet(key: "lastAppcastCheck", value: .string("2026-08-03T00:00:00Z"))),
            (.user, .settingsSet(key: "theme", value: .string("light"))),
            // ext: non-restricted key only (elevated settings stage)
            (.ext(id: "demo"), .settingsSet(key: "ext.demo.flag", value: .number(42))),
            (.user, .settingsDelete(key: "lastAppcastCheck")),
            (.user, .settingsSet(key: "nested", value: .object([
                "a": .bool(true),
                "b": .array([.string("x"), .number(1)]),
            ]))),
        ]

        for (actor, action) in actions {
            let result = try original.dispatch(action: action, actor: actor)
            XCTAssertTrue(result.isApplied, "action \(action.name) should apply")
        }

        let originalBytes = try original.exportJSON()
        let applied = try original.journal.appliedEntries()
        XCTAssertEqual(applied.count, actions.count)

        let fresh = try SummonCore.inMemory()
        try fresh.replay(entries: applied)
        let replayedBytes = try fresh.exportJSON()

        XCTAssertEqual(
            originalBytes,
            replayedBytes,
            """
            Store state not byte-equal after replay.
            original:
            \(String(data: originalBytes, encoding: .utf8) ?? "?")
            replayed:
            \(String(data: replayedBytes, encoding: .utf8) ?? "?")
            """
        )
    }

    func testReplayedCopyHelper() throws {
        let original = try SummonCore.inMemory()
        _ = try original.dispatch(
            action: .settingsSet(key: "k", value: .string("v")),
            actor: .user
        )
        let copy = try original.replayedCopy()
        XCTAssertEqual(try original.exportJSON(), try copy.exportJSON())
    }

    func testRejectedActionsExcludedFromReplayInput() throws {
        let original = try SummonCore.inMemory()
        _ = try original.dispatch(
            action: .settingsSet(key: "ok", value: .string("1")),
            actor: .user
        )
        _ = try original.dispatch(
            action: .settingsSet(key: "", value: .string("bad")),
            actor: .user
        )

        let applied = try original.journal.appliedEntries()
        XCTAssertEqual(applied.count, 1)

        let fresh = try SummonCore.inMemory()
        try fresh.replay(entries: try original.journal.allEntries())
        XCTAssertEqual(try fresh.settings.get("ok"), .string("1"))
        XCTAssertEqual(try fresh.exportJSON(), try original.exportJSON())
    }

    func testCLIEndToEndViaBus() throws {
        // Mirrors summon-cli settings set path without spawning a process.
        let core = try SummonCore.inMemory()
        let value = JSONValue.parseCLI("true")
        let result = try core.dispatch(
            action: .settingsSet(key: "feature.cli_e2e", value: value),
            actor: .agent
        )
        XCTAssertTrue(result.isApplied)
        XCTAssertEqual(try core.settings.get("feature.cli_e2e"), .bool(true))

        let entries = try core.journal.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].actor, .agent)
    }
}
