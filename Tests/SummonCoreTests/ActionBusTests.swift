import GRDB
import XCTest
@testable import SummonCore

final class ActionBusTests: XCTestCase {
    func testUsageRecordRollsBackStoresWhenJournalAppendFails() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        try core.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_usage_journal
                BEFORE INSERT ON action_journal
                WHEN NEW.action_json LIKE '%usage.record%'
                BEGIN
                    SELECT RAISE(ABORT, 'usage journal rejected');
                END;
                """)
        }
        let result = SearchResult(
            id: "file:atomic-usage",
            title: "Atomic.txt",
            kind: .file,
            path: "/tmp/Atomic.txt"
        )

        XCTAssertThrowsError(try core.recordUsage(result: result, query: "atomic-query"))
        XCTAssertTrue(try core.frecency.recents().isEmpty)
        XCTAssertTrue(try core.history.recent().isEmpty)
        XCTAssertTrue(try core.journal.allEntries().isEmpty)
    }

    func testUsageRecordCarriesActorAndReplaysBothStores() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let result = SearchResult(
            id: "file:journaled-usage",
            title: "Journaled.txt",
            kind: .file,
            path: "/tmp/Journaled.txt"
        )

        try core.recordUsage(
            result: result,
            query: "journaled-query",
            actor: .system,
            at: Date(timeIntervalSince1970: 42)
        )

        let entry = try XCTUnwrap(try core.journal.allEntries().last)
        XCTAssertEqual(entry.actor, .system)
        XCTAssertEqual(entry.action.name, "usage.record")
        let replayed = try core.replayedCopy()
        XCTAssertEqual(try replayed.frecency.recents().map(\.resultID), [result.id])
        XCTAssertEqual(try replayed.history.recent().map(\.query), ["journaled-query"])
    }

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

    func testClipboardIgnoreMutationsUseBusAndReplay() throws {
        let core = try SummonCore.inMemory()
        let add = try core.dispatch(
            action: .clipboardIgnoreAdd(entry: "com.example.Secret"),
            actor: .user
        )
        XCTAssertTrue(add.isApplied)
        XCTAssertTrue(try core.clipboardIgnore.isIgnored("com.example.secret"))
        XCTAssertEqual(try core.journal.appliedEntries().last?.actor, .user)

        let replayed = try core.replayedCopy()
        XCTAssertTrue(try replayed.clipboardIgnore.isIgnored("com.example.secret"))

        let remove = try core.dispatch(
            action: .clipboardIgnoreRemove(entry: "com.example.Secret"),
            actor: .user
        )
        XCTAssertTrue(remove.isApplied)
        XCTAssertFalse(try core.clipboardIgnore.isIgnored("com.example.secret"))
    }

    func testClipboardIgnoreRemovalMatchesCaseAndWhitespaceSemantics() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .clipboardIgnoreAdd(entry: "  COM.Example.Secret  "),
            actor: .user
        )
        XCTAssertTrue(try core.clipboardIgnore.isIgnored("com.example.secret"))

        _ = try core.dispatch(
            action: .clipboardIgnoreRemove(entry: "Com.Example.Secret"),
            actor: .user
        )

        XCTAssertFalse(try core.clipboardIgnore.isIgnored("COM.EXAMPLE.SECRET"))
        XCTAssertTrue(try core.clipboardIgnore.all().isEmpty)
    }

    func testModuleEffectDoesNotHoldBusLock() throws {
        let executor = BlockingModuleExecutor()
        let core = try SummonCore.inMemory(executor: executor)
        let effectFinished = expectation(description: "effect finished")
        let mutationFinished = expectation(description: "mutation finished")
        let result = SearchResult(
            id: "app:blocking",
            title: "Blocking",
            kind: .app,
            path: "/Applications/Blocking.app"
        )

        DispatchQueue.global().async {
            _ = try? core.invoke(actionName: "app.open", result: result, actor: .user)
            effectFinished.fulfill()
        }
        XCTAssertEqual(executor.entered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            _ = try? core.dispatch(
                action: .settingsSet(key: "while-effect-runs", value: .bool(true)),
                actor: .user
            )
            mutationFinished.fulfill()
        }
        wait(for: [mutationFinished], timeout: 1)
        executor.release.signal()
        wait(for: [effectFinished], timeout: 1)
        XCTAssertEqual(try core.settings.get("while-effect-runs"), .bool(true))
    }

    func testGenericExecutorFailureIsRejectedAndJournaled() throws {
        let core = try SummonCore.inMemory(executor: GenericThrowingExecutor())
        let result = try core.dispatch(
            action: .moduleRun(
                name: "app.open",
                targetID: "app:missing",
                path: "/Applications/Missing.app",
                payload: [:]
            ),
            actor: .user
        )
        XCTAssertFalse(result.isApplied)
        let entry = try XCTUnwrap(core.journal.allEntries().last)
        XCTAssertEqual(entry.actor, .user)
        XCTAssertEqual(entry.action.name, "module.run")
        XCTAssertTrue(entry.outcome.hasPrefix("rejected:"))
    }

    func testStoreMutationRollsBackWhenJournalInsertFails() throws {
        let core = try SummonCore.inMemory()
        let id = UUID()
        try core.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_test_journal_insert
                BEFORE INSERT ON action_journal
                WHEN NEW.id = '\(id.uuidString)'
                BEGIN
                    SELECT RAISE(ABORT, 'injected journal failure');
                END;
                """)
        }

        XCTAssertThrowsError(
            try core.dispatch(
                action: .settingsSet(key: "atomic", value: .string("value")),
                actor: .user,
                id: id
            )
        )
        XCTAssertNil(try core.settings.get("atomic"))
        XCTAssertTrue(try core.journal.allEntries().isEmpty)
    }

    func testDuplicateStoreEnvelopeReturnsRecordedOutcomeWithoutMutation() throws {
        let core = try SummonCore.inMemory()
        let id = UUID()
        let first = try core.dispatch(
            action: .settingsSet(key: "idempotent", value: .string("first")),
            actor: .user,
            id: id
        )
        let duplicate = try core.dispatch(
            action: .settingsSet(key: "idempotent", value: .string("second")),
            actor: .user,
            id: id
        )

        XCTAssertTrue(first.isApplied)
        XCTAssertTrue(duplicate.isApplied)
        XCTAssertEqual(try core.settings.get("idempotent"), .string("first"))
        XCTAssertEqual(try core.journal.allEntries().count, 1)
    }

    func testDuplicateEffectEnvelopeExecutesOnce() throws {
        let executor = RecordingModuleExecutor()
        let core = try SummonCore.inMemory(executor: executor)
        let envelope = ActionEnvelope(
            actor: .user,
            action: .moduleRun(
                name: "app.open",
                targetID: "app:once",
                path: "/Applications/Once.app",
                payload: [:]
            )
        )

        XCTAssertTrue(try core.dispatch(envelope).isApplied)
        XCTAssertTrue(try core.dispatch(envelope).isApplied)
        XCTAssertEqual(executor.calls.count, 1)
        XCTAssertEqual(try core.journal.allEntries().count, 1)
    }

    func testUnfinishedEffectIntentPreventsRepeat() throws {
        let executor = RecordingModuleExecutor()
        let core = try SummonCore.inMemory(executor: executor)
        let envelope = ActionEnvelope(
            actor: .user,
            action: .moduleRun(
                name: "app.open",
                targetID: "app:pending",
                path: "/Applications/Pending.app",
                payload: [:]
            )
        )
        try core.dbQueue.write { db in
            XCTAssertNil(try core.journal.reserveEffect(envelope, in: db))
        }

        let result = try core.dispatch(envelope)
        XCTAssertFalse(result.isApplied)
        XCTAssertTrue(executor.calls.isEmpty)
        XCTAssertEqual(try core.journal.allEntries().first?.outcome, "intent")
    }

    func testClipboardDeleteCannotRaceAfterCopyJournalScrub() throws {
        let executor = BlockingModuleExecutor(blockOperation: "copy")
        let core = try SummonCore.inMemory(executor: executor)
        let secret = "clipboard-race-secret"
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "race-clip",
                text: secret,
                sourceApp: nil,
                createdAt: Date(),
                pinned: false
            ),
            actor: .system
        )
        let copyFinished = expectation(description: "copy finished")
        let deleteFinished = DispatchSemaphore(value: 0)
        let result = SearchResult(
            id: "clipboard:race-clip",
            title: secret,
            kind: .clipboard,
            payload: [
                "clipboardID": .string("race-clip"),
                "text": .string(secret),
            ]
        )

        DispatchQueue.global().async {
            _ = try? core.invoke(actionName: "clipboard.copy", result: result, actor: .user)
            copyFinished.fulfill()
        }
        XCTAssertEqual(executor.entered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            _ = try? core.dispatch(action: .clipboardDelete(id: "race-clip"), actor: .user)
            deleteFinished.signal()
        }

        XCTAssertEqual(deleteFinished.wait(timeout: .now() + 0.05), .timedOut)
        executor.release.signal()
        wait(for: [copyFinished], timeout: 1)
        XCTAssertEqual(deleteFinished.wait(timeout: .now() + 1), .success)
        let journal = try core.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT action_json FROM action_journal").joined()
        }
        XCTAssertFalse(journal.contains(secret))
    }
}

private struct GenericThrowingExecutor: ModuleExecuting {
    func open(pathOrURL: String) throws {
        throw NSError(
            domain: "ActionBusTests.GenericExecutor",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "generic executor failure"]
        )
    }

    func reveal(path: String) throws {}
    func copyToPasteboard(text: String) throws {}
}

private final class BlockingModuleExecutor: ModuleExecuting, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let blockOperation: String

    init(blockOperation: String = "open") {
        self.blockOperation = blockOperation
    }

    func open(pathOrURL: String) throws {
        guard blockOperation == "open" else { return }
        entered.signal()
        _ = release.wait(timeout: .now() + 2)
    }

    func reveal(path: String) throws {}
    func copyToPasteboard(text: String) throws {
        guard blockOperation == "copy" else { return }
        entered.signal()
        _ = release.wait(timeout: .now() + 2)
    }
}
