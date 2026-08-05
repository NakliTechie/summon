import GRDB
import XCTest
@testable import SummonCore

final class ClipboardPrivacyTests: XCTestCase {
    func testConcealedTypeSkipped() {
        XCTAssertTrue(
            PasteboardPrivacy.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        )
        XCTAssertFalse(
            PasteboardPrivacy.isStorableText(
                types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
                hasString: true
            )
        )
    }

    func testTransientSkipped() {
        XCTAssertTrue(PasteboardPrivacy.shouldSkip(types: ["org.nspasteboard.TransientType"]))
        XCTAssertTrue(PasteboardPrivacy.shouldSkip(types: ["de.petermaurer.TransientPasteboardType"]))
        XCTAssertTrue(PasteboardPrivacy.shouldSkip(types: ["com.summon.clipboard.generated"]))
    }

    func testPlainTextAllowed() {
        XCTAssertFalse(PasteboardPrivacy.shouldSkip(types: ["public.utf8-plain-text"]))
        XCTAssertTrue(
            PasteboardPrivacy.isStorableText(types: ["public.utf8-plain-text"], hasString: true)
        )
    }

    func testIngestAndSearch() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let allowed = try core.ingestClipboard(
            text: "invoice-42",
            types: ["public.utf8-plain-text"],
            sourceApp: "Test"
        )
        XCTAssertNotNil(allowed)
        let skipped = try core.ingestClipboard(
            text: "secret-password",
            types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]
        )
        XCTAssertNil(skipped)

        let results = try core.search.search("invoice kind:clipboard")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].kind, .clipboard)

        let copy = try core.replayedCopy()
        XCTAssertEqual(try core.exportJSON(), try copy.exportJSON())
    }

    func testModuleOpenViaRecordingExecutor() throws {
        let exec = RecordingModuleExecutor()
        let core = try SummonCore.inMemory(appSearchPaths: [], executor: exec)
        let result = SearchResult(
            id: "app:/Applications/Test.app",
            title: "Test",
            kind: .app,
            path: "/Applications/Test.app"
        )
        _ = try core.invoke(actionName: "app.open", result: result, actor: .user)
        XCTAssertEqual(exec.calls.last?.op, "open")
        XCTAssertEqual(exec.calls.last?.value, "/Applications/Test.app")
    }

    func testLauncherSessionObjectMode() throws {
        let exec = RecordingModuleExecutor()
        let core = try SummonCore.inMemory(appSearchPaths: [], executor: exec)
        _ = try core.dispatch(
            action: .quicklinkUpsert(id: "q1", name: "Docs", url: "https://example.com", keyword: "docs"),
            actor: .user
        )
        let session = LauncherSession(core: core)
        _ = try session.setQuery("Docs kind:quicklink")
        XCTAssertEqual(session.results.count, 1)
        session.enterObjectMode()
        XCTAssertTrue(session.objectMode)
        XCTAssertTrue(session.objectActions.contains { $0.name == "quicklink.open" })
        let name = try session.confirm(actor: .user)
        XCTAssertEqual(name, "quicklink.open")
        XCTAssertEqual(exec.calls.last?.op, "open")
    }

    func testClipboardObjectModeCanUnpin() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "pinned-clip",
                text: "pinned",
                sourceApp: nil,
                createdAt: Date(),
                pinned: true
            ),
            actor: .system
        )
        let query = FilterQuery(freeText: "pinned", filters: [])
        let result = try XCTUnwrap(try core.clipboard.search(query: query, limit: 1).first)
        let unpin = try XCTUnwrap(
            ObjectActionGrammar.actions(for: result).first { $0.name == "clipboard.unpin" }
        )

        _ = try core.invoke(actionName: unpin.name, result: result, actor: .user)

        XCTAssertEqual(try core.clipboard.get(id: "pinned-clip")?.isPinned, false)
    }

    func testClipboardReuseMovesItemToTopAndReplays() throws {
        let core = try SummonCore.inMemory(
            appSearchPaths: [],
            executor: RecordingModuleExecutor()
        )
        for (id, text, timestamp) in [("older", "reuse-me", 1.0), ("newer", "other", 2.0)] {
            _ = try core.dispatch(
                action: .clipboardIngest(
                    id: id,
                    text: text,
                    sourceApp: nil,
                    createdAt: Date(timeIntervalSince1970: timestamp),
                    pinned: false
                ),
                actor: .system
            )
        }
        let older = try XCTUnwrap(
            try core.clipboard.search(
                query: FilterQuery(freeText: "reuse", filters: []),
                limit: 1
            ).first
        )

        _ = try core.invoke(actionName: "clipboard.copy", result: older, actor: .user)

        XCTAssertEqual(try core.clipboard.all().first?.id, "older")
        let replayed = try core.replayedCopy()
        XCTAssertEqual(try core.exportJSON(), try replayed.exportJSON())
    }

    func testClipboardDeleteScrubsPlaintextJournalPayloadsAndReplays() throws {
        let secret = "SECRET-delete-me-123"
        let core = try SummonCore.inMemory(appSearchPaths: [], executor: RecordingModuleExecutor())
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "clip-secret",
                text: secret,
                sourceApp: "Test",
                createdAt: Date(),
                pinned: false
            ),
            actor: .system
        )
        _ = try core.invoke(
            actionName: "clipboard.copy",
            result: SearchResult(
                id: "clipboard:clip-secret",
                title: secret,
                kind: .clipboard,
                payload: [
                    "clipboardID": .string("clip-secret"),
                    "text": .string(secret),
                ]
            ),
            actor: .user
        )

        XCTAssertTrue(try journalJSON(core).contains(secret))
        _ = try core.dispatch(action: .clipboardDelete(id: "clip-secret"), actor: .user)

        XCTAssertNil(try core.clipboard.get(id: "clip-secret"))
        XCTAssertFalse(try journalJSON(core).contains(secret))
        let replayed = try core.replayedCopy()
        XCTAssertEqual(try core.exportJSON(), try replayed.exportJSON())
    }

    func testDuplicateIngestUsesRetainedIdentityAndDeleteCannotResurrect() throws {
        let secret = "SECRET-duplicate-replay"
        let core = try SummonCore.inMemory(appSearchPaths: [])
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "older-id",
                text: secret,
                sourceApp: "First",
                createdAt: Date(timeIntervalSince1970: 1),
                pinned: false
            ),
            actor: .system
        )
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "newer-id",
                text: secret,
                sourceApp: "Second",
                createdAt: Date(timeIntervalSince1970: 2),
                pinned: false
            ),
            actor: .system
        )

        XCTAssertNil(try core.clipboard.get(id: "older-id"))
        XCTAssertEqual(try core.clipboard.get(id: "newer-id")?.sourceApp, "Second")
        _ = try core.dispatch(action: .clipboardDelete(id: "newer-id"), actor: .user)

        XCTAssertFalse(try journalJSON(core).contains(secret))
        let replayed = try core.replayedCopy()
        XCTAssertTrue(try replayed.clipboard.all().isEmpty)
        XCTAssertEqual(try core.exportJSON(), try replayed.exportJSON())
    }

    func testClearUnpinnedScrubsOnlyDeletedClipboardPayloads() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "kept",
                text: "PINNED-preserve-me",
                sourceApp: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                pinned: true
            ),
            actor: .system
        )
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "cleared",
                text: "UNPINNED-remove-me",
                sourceApp: nil,
                createdAt: Date(timeIntervalSince1970: 2),
                pinned: false
            ),
            actor: .system
        )

        _ = try core.dispatch(action: .clipboardClearUnpinned, actor: .user)

        XCTAssertNotNil(try core.clipboard.get(id: "kept"))
        XCTAssertNil(try core.clipboard.get(id: "cleared"))
        let journal = try journalJSON(core)
        XCTAssertTrue(journal.contains("PINNED-preserve-me"))
        XCTAssertFalse(journal.contains("UNPINNED-remove-me"))
        let replayed = try core.replayedCopy()
        XCTAssertEqual(try core.exportJSON(), try replayed.exportJSON())
    }

    func testClipboardDeleteScrubsFrecencyHistoryAndUsageJournal() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let secret = "clipboard-frecency-secret-7319"
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "frecency-clip",
                text: secret,
                sourceApp: "Fixture",
                createdAt: Date(timeIntervalSince1970: 1),
                pinned: false
            ),
            actor: .system
        )
        try core.recordUsage(
            result: SearchResult(
                id: "clipboard:frecency-clip",
                title: secret,
                kind: .clipboard,
                payload: [
                    "clipboardID": .string("frecency-clip"),
                    "text": .string(secret),
                ]
            ),
            query: "frecency-secret-query",
            actor: .user,
            at: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(try core.frecency.recents().map(\.resultID), ["clipboard:frecency-clip"])
        XCTAssertEqual(try core.history.recent().map(\.query), ["frecency-secret-query"])

        _ = try core.dispatch(action: .clipboardDelete(id: "frecency-clip"), actor: .user)

        XCTAssertTrue(try core.frecency.recents().isEmpty)
        XCTAssertTrue(try core.history.recent().isEmpty)
        XCTAssertFalse(try journalJSON(core).contains(secret))
        XCTAssertFalse(try journalJSON(core).contains("frecency-secret-query"))
    }

    func testUnpinPrunesAnOverflowingUnpinnedBucket() throws {
        let queue = try SummonDatabase.openInMemory()
        let store = ClipboardStore(dbQueue: queue, unpinnedRetentionLimit: 2)
        try store.ingest(ClipboardItem(
            id: "old-pinned",
            text: "old pinned",
            createdAt: Date(timeIntervalSince1970: 1),
            isPinned: true
        ))
        try store.ingest(ClipboardItem(
            id: "newer-a",
            text: "newer a",
            createdAt: Date(timeIntervalSince1970: 2)
        ))
        try store.ingest(ClipboardItem(
            id: "newer-b",
            text: "newer b",
            createdAt: Date(timeIntervalSince1970: 3)
        ))

        try store.setPinned(id: "old-pinned", pinned: false)

        XCTAssertNil(try store.get(id: "old-pinned"))
        XCTAssertEqual(Set(try store.all().map(\.id)), ["newer-a", "newer-b"])
    }

    func testRetentionPrunesOldestUnpinnedAndScrubsJournal() throws {
        let dbQueue = try SummonDatabase.openInMemory()
        let store = ClipboardStore(dbQueue: dbQueue, unpinnedRetentionLimit: 2)
        let journal = ActionJournal(dbQueue: dbQueue)

        for index in 0..<3 {
            let item = ClipboardItem(
                id: "clip-\(index)",
                text: "retention-secret-\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isPinned: false
            )
            try store.ingest(item)
            try journal.append(
                envelope: ActionEnvelope(
                    actor: .system,
                    action: .clipboardIngest(
                        id: item.id,
                        text: item.text,
                        sourceApp: nil,
                        createdAt: item.createdAt,
                        pinned: false
                    )
                ),
                outcome: .applied
            )
        }

        XCTAssertEqual(try store.all().map(\.id), ["clip-2", "clip-1"])
        let raw = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT action_json FROM action_journal").joined()
        }
        XCTAssertFalse(raw.contains("retention-secret-0"))
        XCTAssertTrue(raw.contains("retention-secret-1"))
        XCTAssertTrue(raw.contains("retention-secret-2"))
    }

    func testRetentionUsesArrivalOrderForBackdatedIngest() throws {
        let dbQueue = try SummonDatabase.openInMemory()
        let store = ClipboardStore(dbQueue: dbQueue, unpinnedRetentionLimit: 2)
        let journal = ActionJournal(dbQueue: dbQueue)
        let items = [
            ClipboardItem(
                id: "arrival-1",
                text: "arrival-secret-1",
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            ClipboardItem(
                id: "arrival-2",
                text: "arrival-secret-2",
                createdAt: Date(timeIntervalSince1970: 200)
            ),
            ClipboardItem(
                id: "backdated-arrival-3",
                text: "arrival-secret-3",
                createdAt: Date(timeIntervalSince1970: 1)
            ),
        ]

        for item in items {
            try store.ingest(item)
            try journal.append(
                envelope: ActionEnvelope(
                    actor: .system,
                    action: .clipboardIngest(
                        id: item.id,
                        text: item.text,
                        sourceApp: nil,
                        createdAt: item.createdAt,
                        pinned: false
                    )
                ),
                outcome: .applied
            )
        }

        XCTAssertNil(try store.get(id: "arrival-1"))
        XCTAssertNotNil(try store.get(id: "arrival-2"))
        XCTAssertNotNil(try store.get(id: "backdated-arrival-3"))
        let raw = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT action_json FROM action_journal").joined()
        }
        XCTAssertFalse(raw.contains("arrival-secret-1"))
        XCTAssertTrue(raw.contains("arrival-secret-3"))
    }

    func testDatabaseOpenHardensExistingContainerAndDatabaseModes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-permissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        let dbQueue = try SummonDatabase.open(in: root)
        _ = dbQueue
        let dbURL = root.appendingPathComponent(SummonDatabase.fileName)
        let containerMode = try posixMode(at: root)
        let databaseMode = try posixMode(at: dbURL)

        XCTAssertEqual(containerMode, SummonDatabase.containerPermissions)
        XCTAssertEqual(databaseMode, SummonDatabase.databasePermissions)
    }

    private func journalJSON(_ core: SummonCore) throws -> String {
        try core.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT action_json FROM action_journal ORDER BY seq"
            ).joined(separator: "\n")
        }
    }

    private func posixMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let raw = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        return raw & 0o777
    }
}
