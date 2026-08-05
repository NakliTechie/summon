import GRDB
import XCTest
@testable import SummonCore

final class RichClipboardTests: XCTestCase {
    func testLegacyClipboardCodecRejectsMissingAndMalformedTimestamp() throws {
        let missing = Data(#"{"name":"clipboard.ingest","id":"clip","text":"body"}"#.utf8)
        let malformed = Data(
            #"{"name":"clipboard.ingest","id":"clip","text":"body","createdAt":"invalid"}"#.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(CoreAction.self, from: missing))
        XCTAssertThrowsError(try JSONDecoder().decode(CoreAction.self, from: malformed))
    }

    func testV3DatabaseMigrationBackfillsPlainTextContentHash() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-v3-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(SummonDatabase.fileName).path
        let legacy = try DatabaseQueue(path: path)
        try legacy.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in ["v1_spine", "v2_snippets", "v3_clipboard_quicklinks"] {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [identifier]
                )
            }
            try db.execute(sql: "CREATE TABLE schema_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
            try db.execute(
                sql: "INSERT INTO schema_meta (key, value) VALUES ('schemaVersion', '3')"
            )
            try db.execute(sql: """
                CREATE TABLE clipboard_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    text TEXT NOT NULL,
                    source_app TEXT,
                    created_at TEXT NOT NULL,
                    is_pinned INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO clipboard_items (id, text, source_app, created_at, is_pinned)
                    VALUES ('legacy', 'legacy text', NULL, '2026-08-04T10:00:00.000Z', 0)
                    """
            )
        }

        let migrated = try SummonDatabase.open(in: root)
        let item = try XCTUnwrap(ClipboardStore(dbQueue: migrated).get(id: "legacy"))
        let schemaVersion = try migrated.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM schema_meta WHERE key = 'schemaVersion'"
            )
        }

        XCTAssertEqual(item.contentKind, .plainText)
        XCTAssertNil(item.data)
        XCTAssertFalse(item.contentHash.isEmpty)
        XCTAssertEqual(schemaVersion, "4")
    }

    func testRichActionCodecRoundTripsBinaryPayloadAndTimestamp() throws {
        let action = CoreAction.clipboardIngestRich(
            id: "codec",
            text: "Hello",
            sourceApp: "TextEdit",
            createdAt: Date(timeIntervalSince1970: 123.456),
            pinned: true,
            contentKind: .richText,
            flavor: "public.rtf",
            data: Data([1, 2, 3, 4])
        )

        let encoded = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(CoreAction.self, from: encoded)

        XCTAssertEqual(decoded, action)
    }

    func testImagePersistsCopiesReplaysAndScrubsOnDelete() throws {
        let executor = RecordingModuleExecutor()
        let core = try SummonCore.inMemory(executor: executor)
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03])
        let action = CoreAction.clipboardIngestRich(
            id: "image-1",
            text: "",
            sourceApp: "Preview",
            createdAt: Date(timeIntervalSince1970: 100),
            pinned: false,
            contentKind: .image,
            flavor: "public.png",
            data: bytes
        )

        XCTAssertTrue(try core.dispatch(action: action, actor: .system).isApplied)
        let stored = try XCTUnwrap(core.clipboard.get(id: "image-1"))
        XCTAssertEqual(stored.data, bytes)
        XCTAssertEqual(stored.contentKind, .image)

        let result = try XCTUnwrap(core.clipboard.search(
            query: FilterQuery(freeText: "image", filters: []),
            limit: 5
        ).first)
        XCTAssertTrue(try core.invoke(actionName: "clipboard.copy", result: result, actor: .user).isApplied)
        XCTAssertEqual(executor.copiedClipboardItems.last, stored)
        XCTAssertEqual(executor.calls.last?.op, "copyClipboard")

        let replayed = try core.replayedCopy()
        XCTAssertEqual(
            try replayed.clipboard.get(id: "image-1"),
            try core.clipboard.get(id: "image-1")
        )

        XCTAssertTrue(try core.dispatch(action: .clipboardDelete(id: "image-1"), actor: .user).isApplied)
        let encoded = bytes.base64EncodedString()
        let journal = try core.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT action_json FROM action_journal").joined()
        }
        XCTAssertFalse(journal.contains(encoded))
        XCTAssertNil(try core.clipboard.get(id: "image-1"))
    }

    func testRichTextDeduplicatesByOriginalPayloadAndPlainCopyUsesExtractedText() throws {
        let executor = RecordingModuleExecutor()
        let core = try SummonCore.inMemory(executor: executor)
        let html = Data("<b>Vec&lt;String&gt;</b>".utf8)

        for id in ["rich-old", "rich-new"] {
            let action = CoreAction.clipboardIngestRich(
                id: id,
                text: "Vec<String>",
                sourceApp: "TextEdit",
                createdAt: Date(),
                pinned: false,
                contentKind: .richText,
                flavor: "public.html",
                data: html
            )
            XCTAssertTrue(try core.dispatch(action: action, actor: .system).isApplied)
        }

        XCTAssertNil(try core.clipboard.get(id: "rich-old"))
        let stored = try XCTUnwrap(core.clipboard.get(id: "rich-new"))
        let richEvents = try core.journal.appliedEntries().filter {
            if case .clipboardIngestRich = $0.action { return true }
            return false
        }
        XCTAssertEqual(richEvents.count, 1)
        let result = try XCTUnwrap(core.clipboard.search(
            query: FilterQuery(freeText: "Vec<String>", filters: []),
            limit: 5
        ).first)
        XCTAssertTrue(try core.invoke(actionName: "clipboard.copyPlain", result: result, actor: .user).isApplied)
        XCTAssertEqual(executor.pasteboard, "Vec<String>")
        XCTAssertEqual(executor.calls.last?.op, "copyClipboardPlain")
        XCTAssertEqual(stored.data, html)
    }

    func testImagePinClearAndRetentionPreservePrivacyInvariants() throws {
        let core = try SummonCore.inMemory()
        let pinnedBytes = Data([9, 9, 9, 9])
        let clearedBytes = Data([8, 8, 8, 8])
        for (id, bytes) in [("pinned-image", pinnedBytes), ("cleared-image", clearedBytes)] {
            XCTAssertTrue(try core.dispatch(
                action: .clipboardIngestRich(
                    id: id,
                    text: "",
                    sourceApp: "Preview",
                    createdAt: Date(),
                    pinned: false,
                    contentKind: .image,
                    flavor: "public.png",
                    data: bytes
                ),
                actor: .system
            ).isApplied)
        }
        XCTAssertTrue(try core.dispatch(
            action: .clipboardPin(id: "pinned-image", pinned: true),
            actor: .user
        ).isApplied)
        XCTAssertTrue(try core.dispatch(action: .clipboardClearUnpinned, actor: .user).isApplied)

        XCTAssertTrue(try core.clipboard.get(id: "pinned-image")?.isPinned == true)
        XCTAssertNil(try core.clipboard.get(id: "cleared-image"))
        let journal = try core.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT action_json FROM action_journal").joined()
        }
        XCTAssertTrue(journal.contains(pinnedBytes.base64EncodedString()))
        XCTAssertFalse(journal.contains(clearedBytes.base64EncodedString()))
        XCTAssertEqual(try core.exportJSON(), try core.replayedCopy().exportJSON())

        let dbQueue = try SummonDatabase.openInMemory()
        let store = ClipboardStore(dbQueue: dbQueue, unpinnedRetentionLimit: 1)
        let retentionJournal = ActionJournal(dbQueue: dbQueue)
        for (index, byte) in [(1, UInt8(0x11)), (2, UInt8(0x22))] {
            let item = ClipboardItem(
                id: "retained-image-\(index)",
                text: "",
                createdAt: Date(),
                contentKind: .image,
                flavor: "public.png",
                data: Data([byte, byte, byte])
            )
            try store.ingest(item)
            let itemData = try XCTUnwrap(item.data)
            try retentionJournal.append(
                envelope: ActionEnvelope(
                    actor: .system,
                    action: .clipboardIngestRich(
                        id: item.id,
                        text: item.text,
                        sourceApp: nil,
                        createdAt: item.createdAt,
                        pinned: false,
                        contentKind: .image,
                        flavor: "public.png",
                        data: itemData
                    )
                ),
                outcome: .applied
            )
        }
        XCTAssertNil(try store.get(id: "retained-image-1"))
        XCTAssertNotNil(try store.get(id: "retained-image-2"))
        XCTAssertEqual(try retentionJournal.appliedEntries().count, 1)
    }

    func testConcealedImageIsRejectedBeforeIngest() throws {
        let core = try SummonCore.inMemory()
        let item = ClipboardItem(
            text: "",
            contentKind: .image,
            flavor: "public.png",
            data: Data([1, 2, 3])
        )

        let result = try core.ingestClipboard(
            item: item,
            types: ["public.png", "org.nspasteboard.ConcealedType"]
        )

        XCTAssertNil(result)
        XCTAssertTrue(try core.clipboard.all().isEmpty)
        XCTAssertTrue(try core.journal.allEntries().isEmpty)
    }

    func testImageActionsOmitPlainTextConversion() throws {
        let result = SearchResult(
            id: "clipboard:image",
            title: "Image",
            kind: .clipboard,
            payload: ["contentKind": .string(ClipboardContentKind.image.rawValue)]
        )

        let actions = ObjectActionGrammar.actions(for: result)

        XCTAssertFalse(actions.contains { $0.name == "clipboard.copyPlain" })
        XCTAssertTrue(actions.contains { $0.name == "clipboard.copy" })
    }

    func testOversizedRichPayloadRejectsBeforeLiveIngestDispatch() throws {
        let core = try SummonCore.inMemory()
        let data = Data(repeating: 0x41, count: ClipboardStore.maximumPayloadBytes + 1)
        let item = ClipboardItem(
            id: "oversized",
            text: "large",
            contentKind: .richText,
            flavor: "public.html",
            data: data
        )

        XCTAssertThrowsError(
            try core.ingestClipboard(item: item, types: ["public.html"], actor: .system)
        )
        XCTAssertNil(try core.clipboard.get(id: "oversized"))
        XCTAssertTrue(try core.journal.allEntries().isEmpty)
    }

    func testPinnedOverflowKeepsMatchingUnpinnedImageReachable() throws {
        let core = try SummonCore.inMemory()
        let sameDate = Date(timeIntervalSince1970: 100)
        for index in 0 ... 500 {
            try core.clipboard.ingest(
                ClipboardItem(
                    id: "pin-\(index)",
                    text: "Image",
                    createdAt: sameDate.addingTimeInterval(Double(index)),
                    isPinned: true
                )
            )
        }
        try core.clipboard.ingest(
            ClipboardItem(
                id: "reachable-image",
                text: "",
                createdAt: sameDate.addingTimeInterval(1_000),
                contentKind: .image,
                flavor: "public.png",
                data: Data([1, 2, 3])
            )
        )

        let historyMatches = try core.clipboard.matchingMetadataPage("image", perBucketLimit: 500)
        let searchMatches = try core.clipboard.search(
            query: FilterQuery(freeText: "image", filters: []),
            limit: 50
        )
        let emptySearchMatches = try core.clipboard.search(
            query: FilterQuery(freeText: "", filters: []),
            limit: 50
        )

        XCTAssertEqual(historyMatches.filter(\.isPinned).count, 500)
        XCTAssertTrue(historyMatches.contains { $0.id == "reachable-image" })
        XCTAssertTrue(searchMatches.contains { $0.id == "clipboard:reachable-image" })
        XCTAssertTrue(emptySearchMatches.contains { $0.id == "clipboard:reachable-image" })
    }

    func testPinnedImageMetadataPageIsBoundedAndLoadsPayloadByID() throws {
        let core = try SummonCore.inMemory()
        for index in 0 ... 1_000 {
            try core.clipboard.ingest(
                ClipboardItem(
                    id: "bounded-image-\(index)",
                    text: "",
                    createdAt: Date(timeIntervalSince1970: Double(index)),
                    isPinned: true,
                    contentKind: .image,
                    flavor: "public.png",
                    data: Data([UInt8(index % 255), 2, 3])
                )
            )
        }

        let page = try core.clipboard.metadataPage(perBucketLimit: 40)
        let selected = try XCTUnwrap(page.first)
        let loaded = try XCTUnwrap(core.clipboard.get(id: selected.id))

        XCTAssertEqual(page.count, 40)
        XCTAssertEqual(selected.contentKind, .image)
        XCTAssertEqual(loaded.data?.count, 3)
        XCTAssertEqual(try core.clipboard.all(limit: 40).count, 40)
    }

    func testClipboardExcludingExportDoesNotReadClipboardRows() throws {
        let core = try SummonCore.inMemory()
        try core.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO clipboard_items (
                        id, text, source_app, created_at, is_pinned,
                        content_kind, flavor, payload, content_hash
                    )
                    VALUES ('unreadable', '', NULL, 'not-a-date', 1,
                            'image', 'public.png', zeroblob(1048576), 'hash')
                    """
            )
        }

        let data = try DataExport.export(core: core, includeClipboard: false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(StoreExportBundle.self, from: data)

        XCTAssertTrue(bundle.snapshot.clipboard.isEmpty)
        XCTAssertThrowsError(try core.snapshot(includeClipboard: true))
    }
}
