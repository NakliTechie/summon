import XCTest
@testable import SummonCore

final class ActionBusTests: XCTestCase {
    func testSettingsSetAndGet() throws {
        let core = try SummonCore.inMemory()
        let result = try core.dispatch(
            action: .settingsSet(key: "theme", value: .string("dark")),
            actor: .user
        )
        XCTAssertTrue(result.isApplied)
        XCTAssertEqual(try core.settings.get("theme"), .string("dark"))
    }

    func testSettingsDelete() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .settingsSet(key: "x", value: .number(1)),
            actor: .user
        )
        _ = try core.dispatch(
            action: .settingsDelete(key: "x"),
            actor: .user
        )
        XCTAssertNil(try core.settings.get("x"))
    }

    func testJournalRecordsActor() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .settingsSet(key: "a", value: .bool(true)),
            actor: .agent
        )
        let entries = try core.journal.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].actor, .agent)
        XCTAssertEqual(entries[0].outcome, "applied")
        XCTAssertEqual(entries[0].action, .settingsSet(key: "a", value: .bool(true)))
    }

    func testExternalDispatchThroughSchemaGate() throws {
        let core = try SummonCore.inMemory()
        let data = try core.schemaGate.encodeDocument(
            .settingsSet(key: "locale", value: .string("en"))
        )
        let result = try core.dispatchExternal(data, actor: .ext(id: "test"))
        XCTAssertTrue(result.isApplied)
        XCTAssertEqual(try core.settings.get("locale"), .string("en"))
        let entries = try core.journal.allEntries()
        XCTAssertEqual(entries[0].actor, .ext(id: "test"))
    }

    func testEmptyKeyRejectedAndJournaled() throws {
        let core = try SummonCore.inMemory()
        let result = try core.dispatch(
            action: .settingsSet(key: "", value: .string("x")),
            actor: .user
        )
        XCTAssertFalse(result.isApplied)
        if case .rejected = result.outcome {
            // expected
        } else {
            XCTFail("expected rejected")
        }
        let entries = try core.journal.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].outcome.hasPrefix("rejected:"))
    }

    func testOnDiskContainer() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let core = try SummonCore(containerURL: tmp)
        _ = try core.dispatch(
            action: .settingsSet(key: "persisted", value: .string("yes")),
            actor: .system
        )

        let reopened = try SummonCore(containerURL: tmp)
        XCTAssertEqual(try reopened.settings.get("persisted"), .string("yes"))
        XCTAssertEqual(try reopened.journal.allEntries().count, 1)
    }
}
