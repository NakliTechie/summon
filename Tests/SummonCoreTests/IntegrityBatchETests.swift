import GRDB
import XCTest
@testable import SummonCore

final class IntegrityBatchETests: XCTestCase {
    func testReplayDoesNotDoubleJournal() throws {
        let original = try SummonCore.inMemory()
        _ = try original.dispatch(
            action: .settingsSet(key: "k", value: .string("v")),
            actor: .user
        )
        let applied = try original.journal.appliedEntries()
        XCTAssertEqual(applied.count, 1)

        let fresh = try SummonCore.inMemory()
        try fresh.replay(entries: applied)
        // Replay must not append to fresh journal
        XCTAssertEqual(try fresh.journal.allEntries().count, 0)
        XCTAssertEqual(try fresh.settings.get("k"), .string("v"))
        XCTAssertEqual(try original.exportJSON(), try fresh.exportJSON())
    }

    func testReplayAppliesAgentHistoricalActionsWithoutRestage() throws {
        let original = try SummonCore.inMemory()
        // Agent non-restricted setting applies
        _ = try original.dispatch(
            action: .settingsSet(key: "feature.x", value: .bool(true)),
            actor: .agent
        )
        // Agent destructive stages — not in appliedEntries
        _ = try original.dispatch(action: .clipboardClearUnpinned, actor: .agent)
        let applied = try original.journal.appliedEntries()
        XCTAssertEqual(applied.count, 1)

        let fresh = try SummonCore.inMemory()
        try fresh.replay(entries: applied)
        XCTAssertEqual(try fresh.settings.get("feature.x"), .bool(true))
        XCTAssertEqual(try fresh.journal.allEntries().count, 0)
    }

    func testImportVersionGate() throws {
        let core = try SummonCore.inMemory()
        let bad = Data(#"""
        {"version":99,"exportedAt":"2026-01-01T00:00:00Z",
         "snapshot":{"schemaVersion":3,"settings":{},"snippets":[],"clipboard":[],"quicklinks":[]},
         "aliases":[],"favorites":[],"includeClipboard":false}
        """#.utf8)
        XCTAssertThrowsError(try DataExport.importJSON(bad, into: core))
    }

    func testImportSettingsViaBus() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .settingsSet(key: "theme", value: .string("dark")),
            actor: .user
        )
        let data = try DataExport.export(core: core)
        let core2 = try SummonCore.inMemory()
        try DataExport.importJSON(data, into: core2)
        XCTAssertEqual(try core2.settings.get("theme"), .string("dark"))
        // Import journals settings writes
        XCTAssertFalse(try core2.journal.appliedEntries().isEmpty)
    }

    func testImportFileReaderRejectsSparseFileAboveLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-oversized-import-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("{}".utf8)))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(SchemaGate.maximumImportDocumentBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try DataExport.readImportFile(at: url))
    }

    func testImportRejectsUnknownFieldsAndCallerActorBeforeMutation() throws {
        let source = try SummonCore.inMemory()
        _ = try source.dispatch(
            action: .snippetUpsert(id: "s1", name: "One", body: "body", keyword: nil),
            actor: .user
        )
        let exported = try DataExport.export(core: source)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exported) as? [String: Any]
        )
        root["unexpected"] = true
        let unknownRoot = try JSONSerialization.data(withJSONObject: root)

        let target = try SummonCore.inMemory()
        XCTAssertThrowsError(try DataExport.importJSON(unknownRoot, into: target))
        XCTAssertThrowsError(
            try DataExport.importJSON(exported, into: target, actor: .agent)
        )
        XCTAssertTrue(try target.snippets.all().isEmpty)
        XCTAssertTrue(try target.journal.allEntries().isEmpty)

        root.removeValue(forKey: "unexpected")
        var snapshot = try XCTUnwrap(root["snapshot"] as? [String: Any])
        var snippets = try XCTUnwrap(snapshot["snippets"] as? [[String: Any]])
        snippets[0]["unexpected"] = "value"
        snapshot["snippets"] = snippets
        root["snapshot"] = snapshot
        let unknownNested = try JSONSerialization.data(withJSONObject: root)
        XCTAssertThrowsError(try DataExport.importJSON(unknownNested, into: target))
        XCTAssertTrue(try target.snippets.all().isEmpty)
    }

    func testImportFailureRollsBackEarlierMutationsAndJournalRows() throws {
        let bundle = StoreExportBundle(
            snapshot: CoreSnapshot(
                settings: ["theme": .string("dark")],
                snippets: [Snippet(id: "invalid", name: "", body: "body")]
            ),
            aliases: [],
            favorites: []
        )
        let data = try encode(bundle)
        let target = try SummonCore.inMemory()

        XCTAssertThrowsError(try DataExport.importJSON(data, into: target))
        XCTAssertNil(try target.settings.get("theme"))
        XCTAssertTrue(try target.snippets.all().isEmpty)
        XCTAssertTrue(try target.journal.allEntries().isEmpty)
    }

    func testImportJournalFailureRollsBackWholeBatch() throws {
        let bundle = StoreExportBundle(
            snapshot: CoreSnapshot(
                settings: ["theme": .string("dark")],
                snippets: [Snippet(id: "s1", name: "One", body: "body")]
            ),
            aliases: [],
            favorites: []
        )
        let target = try SummonCore.inMemory()
        try target.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_import_journal
                BEFORE INSERT ON action_journal
                WHEN NEW.action_json LIKE '%snippet.upsert%'
                BEGIN
                    SELECT RAISE(ABORT, 'injected import journal failure');
                END
                """)
        }

        XCTAssertThrowsError(try DataExport.importJSON(try encode(bundle), into: target))
        XCTAssertNil(try target.settings.get("theme"))
        XCTAssertTrue(try target.snippets.all().isEmpty)
        XCTAssertTrue(try target.journal.allEntries().isEmpty)
    }

    func testImportMergeAndReplaceSemanticsAreExplicitAndReplayable() throws {
        let target = try SummonCore.inMemory()
        _ = try target.dispatch(
            action: .settingsSet(key: "existing", value: .bool(true)),
            actor: .user
        )
        _ = try target.dispatch(
            action: .snippetUpsert(id: "old", name: "Old", body: "old", keyword: nil),
            actor: .user
        )
        _ = try target.dispatch(
            action: .clipboardIngest(
                id: "private",
                text: "preserved",
                sourceApp: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                pinned: false
            ),
            actor: .user
        )
        let alias = LearnedAlias(
            keyword: "new",
            targetResultID: "app:new",
            title: "New",
            kind: "app",
            payload: [:]
        )
        let favorite = FavoriteItem(
            id: "favorite-new",
            resultID: "app:new",
            title: "New",
            kind: "app"
        )
        let bundle = StoreExportBundle(
            snapshot: CoreSnapshot(
                settings: ["imported": .bool(true)],
                snippets: [Snippet(id: "new", name: "New", body: "new")]
            ),
            aliases: [alias],
            favorites: [favorite]
        )
        let data = try encode(bundle)

        try DataExport.importJSON(data, into: target, mode: .merge)
        XCTAssertEqual(Set(try target.snippets.all().map(\.id)), ["old", "new"])
        XCTAssertEqual(try target.settings.get("existing"), .bool(true))

        try DataExport.importJSON(data, into: target, mode: .replace)
        XCTAssertEqual(try target.snippets.all().map(\.id), ["new"])
        XCTAssertNil(try target.settings.get("existing"))
        XCTAssertEqual(try target.settings.get("imported"), .bool(true))
        XCTAssertNotNil(try target.clipboard.get(id: "private"))
        XCTAssertEqual(try target.aliases.all(), [alias])
        XCTAssertEqual(try target.favorites.all(), [favorite])
        XCTAssertTrue(try target.journal.appliedEntries().contains {
            $0.action.name == "import.reset"
        })

        let replayed = try target.replayedCopy()
        XCTAssertEqual(try replayed.snippets.all(), try target.snippets.all())
        XCTAssertEqual(try replayed.aliases.all(), try target.aliases.all())
        XCTAssertEqual(try replayed.favorites.all(), try target.favorites.all())
        XCTAssertEqual(try replayed.settings.all(), try target.settings.all())
        XCTAssertEqual(try replayed.clipboard.all(), try target.clipboard.all())
    }

    func testMergeResolvesFavoritePrimaryKeyCollisionDeterministically() throws {
        let target = try SummonCore.inMemory()
        _ = try target.dispatch(
            action: .favoriteAdd(
                id: "shared-id",
                resultID: "app:existing",
                title: "Existing",
                kind: "app",
                path: nil
            ),
            actor: .user
        )
        let bundle = StoreExportBundle(
            snapshot: CoreSnapshot(settings: [:]),
            aliases: [],
            favorites: [FavoriteItem(
                id: "shared-id",
                resultID: "app:imported",
                title: "Imported",
                kind: "app"
            )]
        )
        let data = try encode(bundle)

        try DataExport.importJSON(data, into: target, mode: .merge)
        let firstImport = try target.favorites.all()
        try DataExport.importJSON(data, into: target, mode: .merge)
        let secondImport = try target.favorites.all()

        XCTAssertEqual(firstImport.count, 2)
        XCTAssertEqual(Set(firstImport.map(\.resultID)), ["app:existing", "app:imported"])
        XCTAssertEqual(Set(firstImport.map(\.id)).count, 2)
        XCTAssertEqual(secondImport, firstImport)
        XCTAssertEqual(try target.replayedCopy().favorites.all(), firstImport)
    }

    func testExportUsesOneSnapshotAcrossStoreDomains() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-export-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let reader = try SummonCore(containerURL: container)
        let writer = try SummonCore(containerURL: container)
        _ = try reader.dispatch(
            action: .settingsSet(key: "snapshot.marker", value: .string("before")),
            actor: .user
        )
        var mutationError: Error?

        let bundle = try reader.storeExportBundle(
            includeClipboard: false,
            exportedAt: Date(timeIntervalSince1970: 10),
            afterSnapshotStart: {
                do {
                    _ = try writer.dispatch(
                        action: .snippetUpsert(
                            id: "concurrent",
                            name: "Concurrent",
                            body: "after snapshot",
                            keyword: nil
                        ),
                        actor: .user
                    )
                } catch {
                    mutationError = error
                }
            }
        )

        XCTAssertNil(mutationError)
        XCTAssertEqual(bundle.snapshot.settings["snapshot.marker"], .string("before"))
        XCTAssertFalse(bundle.snapshot.snippets.contains { $0.id == "concurrent" })
        XCTAssertNotNil(try reader.snippets.get(id: "concurrent"))
    }

    func testRichClipboardImportRequiresDualOptInAndPreservesPayloads() throws {
        let source = try SummonCore.inMemory()
        let html = Data("<b>hello</b>".utf8)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        _ = try source.dispatch(
            action: .clipboardIngestRich(
                id: "html",
                text: "hello",
                sourceApp: "com.example.Source",
                createdAt: Date(timeIntervalSince1970: 10),
                pinned: true,
                contentKind: .richText,
                flavor: "public.html",
                data: html
            ),
            actor: .user
        )
        _ = try source.dispatch(
            action: .clipboardIngestRich(
                id: "image",
                text: "",
                sourceApp: "com.example.Source",
                createdAt: Date(timeIntervalSince1970: 20),
                pinned: true,
                contentKind: .image,
                flavor: "public.png",
                data: png
            ),
            actor: .user
        )
        let data = try DataExport.export(core: source, includeClipboard: true)

        let withoutCallerConsent = try SummonCore.inMemory()
        try DataExport.importJSON(data, into: withoutCallerConsent)
        XCTAssertTrue(try withoutCallerConsent.clipboard.all().isEmpty)

        let imported = try SummonCore.inMemory()
        try DataExport.importJSON(data, into: imported, importClipboard: true)
        XCTAssertEqual(try imported.clipboard.get(id: "html")?.data, html)
        XCTAssertEqual(try imported.clipboard.get(id: "image")?.data, png)
        XCTAssertEqual(
            try imported.journal.appliedEntries().filter {
                $0.action.name == "clipboard.ingestRich"
            }.count,
            2
        )
    }

    func testPersistentDatabaseUsesWALAndBoundedBusyTimeout() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-wal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let core = try SummonCore(containerURL: container)

        let mode = try core.dbQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        let timeout = try core.dbQueue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA busy_timeout")
        }
        XCTAssertEqual(mode?.lowercased(), "wal")
        XCTAssertEqual(timeout, Int(SummonDatabase.busyTimeoutSeconds * 1_000))
    }

    func testSecondQueueWriterWaitsForFirstWriterWithinTimeout() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-contention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let first = try SummonCore(containerURL: container)
        let second = try SummonCore(containerURL: container)
        let lockHeld = expectation(description: "first writer holds transaction")
        let firstFinished = expectation(description: "first writer finished")
        let secondFinished = expectation(description: "second writer finished")
        let releaseFirst = DispatchSemaphore(value: 0)
        let outcome = ConcurrentWriteOutcome()

        DispatchQueue.global().async {
            do {
                try first.dbQueue.write { db in
                    try db.execute(
                        sql: "INSERT INTO settings (key, value_json) VALUES ('first', 'true')"
                    )
                    lockHeld.fulfill()
                    releaseFirst.wait()
                }
            } catch {
                outcome.record(error)
            }
            firstFinished.fulfill()
        }
        wait(for: [lockHeld], timeout: 1)
        DispatchQueue.global().async {
            do {
                let result = try second.dispatch(
                    action: .settingsSet(key: "second", value: .bool(true)),
                    actor: .user
                )
                outcome.record(result)
            } catch {
                outcome.record(error)
            }
            secondFinished.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        releaseFirst.signal()
        wait(for: [firstFinished, secondFinished], timeout: 3)

        XCTAssertTrue(outcome.errors.isEmpty)
        XCTAssertTrue(outcome.result?.isApplied == true)
        XCTAssertEqual(try first.settings.get("second"), .bool(true))
    }

    func testCLIProcessWriterWaitsForAppWriterWithinTimeout() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-process-contention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let appCore = try SummonCore(containerURL: container)
        let cliBinary = try summonCLIBinaryURL()
        let lockHeld = expectation(description: "app writer holds transaction")
        let appFinished = expectation(description: "app writer finished")
        let releaseApp = DispatchSemaphore(value: 0)
        let outcome = ConcurrentWriteOutcome()

        DispatchQueue.global().async {
            do {
                try appCore.dbQueue.write { db in
                    try db.execute(
                        sql: "INSERT INTO settings (key, value_json) VALUES ('app.writer', 'true')"
                    )
                    lockHeld.fulfill()
                    releaseApp.wait()
                }
            } catch {
                outcome.record(error)
            }
            appFinished.fulfill()
        }
        wait(for: [lockHeld], timeout: 1)

        let process = Process()
        process.executableURL = cliBinary
        process.arguments = ["settings", "set", "cli.writer", "true"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HOME": container.path,
            "SUMMON_CONTAINER_DIR": container.path,
        ]) { _, taskValue in taskValue }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(process.isRunning)

        releaseApp.signal()
        process.waitUntilExit()
        wait(for: [appFinished], timeout: 3)

        let processOutput = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(outcome.errors.isEmpty)
        XCTAssertEqual(process.terminationStatus, 0, processOutput)
        XCTAssertEqual(try appCore.settings.get("cli.writer"), .bool(true))
        XCTAssertTrue(try appCore.journal.allEntries().contains {
            $0.actor == .user && $0.action == .settingsSet(key: "cli.writer", value: .bool(true))
        })
    }

    func testSearXNGRejectsNonLoopbackByDefault() async {
        var cfg = WebSearchConfig(enabled: true, baseURL: "http://example.com:8080")
        let client = SearXNGClient(config: cfg)
        do {
            _ = try await client.search(query: "x")
            XCTFail("expected invalid base URL")
        } catch let e as WebSearchError {
            XCTAssertEqual(e, .invalidBaseURL)
        } catch {
            XCTFail("\(error)")
        }
        cfg.allowNonLoopback = true
        // Still may fail network — just allow host check to pass by constructing allowed
        XCTAssertTrue(WebSearchConfig.isAllowedHost(
            URL(string: "http://example.com")!,
            allowNonLoopback: true
        ))
        XCTAssertTrue(WebSearchConfig.isAllowedHost(
            URL(string: "http://127.0.0.1:8080")!,
            allowNonLoopback: false
        ))
    }

    func testFTSPhraseQuoteSurvivesOperators() throws {
        let core = try SummonCore.inMemory()
        try core.grantFTSConsent()
        try core.setFTSEnabled(true)
        try core.fts.upsert(FTSDocument(id: "1", title: "doc", body: "hello world", path: nil))
        // Operator-like tokens must not throw (phrase-quoted MATCH)
        XCTAssertNoThrow(try core.fts.search(query: "hello AND OR NOT", limit: 10))
        let hits = try core.fts.search(query: "hello world", limit: 10)
        XCTAssertFalse(hits.isEmpty)
    }

    func testMDQueryEscape() {
        let e = MdfindSpotlightIndex.escapeMDQuery(#"foo*bar"baz\"#)
        XCTAssertFalse(e.contains("*"))
        XCTAssertFalse(e.contains("\""))
    }

    /// Short free text must not shell mdfind (UI hang / latency regression).
    func testMdfindSkipsShortFreeText() throws {
        let index = MdfindSpotlightIndex()
        let short = FilterQuery(freeText: "c", filters: [])
        let hits = try index.search(query: short, limit: 10)
        XCTAssertTrue(hits.isEmpty, "1-char free text must skip mdfind")
        let two = FilterQuery(freeText: "ab", filters: [])
        XCTAssertTrue(try index.search(query: two, limit: 10).isEmpty, "2-char free text must skip mdfind")
        let empty = FilterQuery(freeText: "", filters: [])
        XCTAssertTrue(try index.search(query: empty, limit: 10).isEmpty)
    }

    func testMdfindRejectsShortNamedKindPredicateBeforeLaunch() {
        let shortName = FilterQuery(
            freeText: "",
            filters: [.name("ab"), .kind("pdf")]
        )
        XCTAssertNil(MdfindSpotlightIndex.queryPredicate(for: shortName))

        let validName = FilterQuery(
            freeText: "",
            filters: [.name("invoice"), .kind("pdf")]
        )
        XCTAssertNotNil(MdfindSpotlightIndex.queryPredicate(for: validName))
    }

    func testExportRoundTripsEveryRestorableDomainAndArchivesJournalMetadata() throws {
        let source = try SummonCore.inMemory(appSearchPaths: [])
        _ = try source.dispatch(
            action: .clipboardIgnoreAdd(entry: "COM.Example.Secret"),
            actor: .user
        )
        try source.recordUsage(
            result: SearchResult(
                id: "file:exported",
                title: "Exported.txt",
                kind: .file,
                path: "/tmp/Exported.txt"
            ),
            query: "exported query",
            actor: .user,
            at: Date(timeIntervalSince1970: 10)
        )
        let stagedID = UUID().uuidString
        try source.staged.upsert(PersistedStagedProposal(
            id: stagedID,
            createdAt: Date(timeIntervalSince1970: 11),
            rung: "L0",
            prompt: "exported prompt",
            output: "exported output"
        ))
        _ = try source.dispatch(
            action: .clipboardIngest(
                id: "private-export-clip",
                text: "clipboard-export-secret-4862",
                sourceApp: nil,
                createdAt: Date(timeIntervalSince1970: 12),
                pinned: false
            ),
            actor: .system
        )
        try source.recordUsage(
            result: SearchResult(
                id: "clipboard:private-export-clip",
                title: "clipboard-export-secret-4862",
                kind: .clipboard,
                payload: ["text": .string("clipboard-export-secret-4862")]
            ),
            query: "clipboard export query",
            actor: .user,
            at: Date(timeIntervalSince1970: 13)
        )

        let data = try DataExport.export(core: source, includeClipboard: false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(StoreExportBundle.self, from: data)

        XCTAssertEqual(bundle.version, StoreExportBundle.currentVersion)
        XCTAssertEqual(bundle.clipboardIgnore, ["com.example.secret"])
        XCTAssertEqual(bundle.frecency.map(\.resultID), ["file:exported"])
        XCTAssertEqual(bundle.history.map(\.query), ["clipboard export query", "exported query"])
        XCTAssertEqual(bundle.stagedProposals.map(\.id), [stagedID])
        XCTAssertGreaterThan(bundle.journalTotalCount, 0)
        XCTAssertFalse(bundle.journal.isEmpty)
        let exportText = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(exportText.contains("clipboard-export-secret-4862"))

        let target = try SummonCore.inMemory(appSearchPaths: [])
        _ = try target.dispatch(
            action: .clipboardIgnoreAdd(entry: "old.example"),
            actor: .user
        )
        try target.recordUsage(
            result: SearchResult(id: "file:old", title: "Old", kind: .file),
            query: "old query"
        )
        try target.staged.upsert(PersistedStagedProposal(
            id: UUID().uuidString,
            rung: "L0",
            prompt: "old",
            output: "old"
        ))

        try DataExport.importJSON(data, into: target, mode: .replace)

        XCTAssertEqual(try target.clipboardIgnore.all(), ["com.example.secret"])
        XCTAssertEqual(try target.frecency.recents().map(\.resultID), ["file:exported"])
        XCTAssertEqual(
            try target.history.recent().map(\.query),
            ["clipboard export query", "exported query"]
        )
        XCTAssertEqual(try target.staged.list(state: nil).map(\.id), [stagedID])
        XCTAssertFalse(try target.journal.allEntries().contains { $0.id == bundle.journal.first?.id })
    }

    private func encode(_ bundle: StoreExportBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    private func summonCLIBinaryURL() throws -> URL {
        let starts = [
            Bundle(for: IntegrityBatchETests.self).bundleURL.deletingLastPathComponent(),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
        ]
        for start in starts {
            var directory = start
            for _ in 0..<8 {
                let candidate = directory.appendingPathComponent("summon-cli")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
                directory.deleteLastPathComponent()
            }
        }
        throw CoreError.io("summon-cli test binary not found")
    }
}

private final class ConcurrentWriteOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var result: ActionResult?
    private(set) var errors: [Error] = []

    func record(_ result: ActionResult) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func record(_ error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }
}
