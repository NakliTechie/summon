import XCTest
@testable import SummonCore

/// Swift file-name index, layer 1: ignore rules, matcher tiers, crawl recall
/// against a ground-truth walk, snapshot round trip, and watcher updates.
final class FileIndexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("summon-fileindex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: FileIndexService.resolvedPath(base.path), isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Fixture

    private func touch(_ relative: String, _ contents: String = "") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    /// A tree with a git repo (ignore rules at two levels) beside plain folders.
    private func makeTree() throws {
        try touch("notes/main.rs")
        try touch("notes/Quarterly Invoice.pdf")
        try touch("notes/photo.heic")
        try touch("plain/node_modules/pkg/index.js")
        try touch("plain/build/out.o")
        try touch("plain/.gitignore", "*.o\n") // outside a repo: not honoured
        try touch("repo/.git/HEAD", "ref: refs/heads/main\n")
        try touch("repo/.git/info/exclude", "secret.txt\n")
        try touch("repo/.gitignore", "build/\n*.log\n!keep.log\n/rootonly.txt\n")
        try touch("repo/src/main.rs")
        try touch("repo/src/app.log")
        try touch("repo/src/keep.log")
        try touch("repo/src/rootonly.txt")
        try touch("repo/rootonly.txt")
        try touch("repo/secret.txt")
        try touch("repo/build/artifact.bin")
        try touch("repo/docs/.gitignore", "draft-*.md\n")
        try touch("repo/docs/draft-1.md")
        try touch("repo/docs/guide.md")
        try touch("fsearch/src/main.rs")
        try touch(".hidden/main.rs")
    }

    /// Every path the index must hold: a plain walk minus the documented exclusions.
    private let expectedRelativePaths: Set<String> = [
        "notes", "notes/main.rs", "notes/Quarterly Invoice.pdf", "notes/photo.heic",
        "plain", "plain/node_modules", "plain/node_modules/pkg", "plain/node_modules/pkg/index.js",
        "plain/build", "plain/build/out.o", "plain/.gitignore",
        "repo", "repo/.gitignore", "repo/src", "repo/src/main.rs", "repo/src/keep.log", "repo/src/rootonly.txt",
        "repo/docs", "repo/docs/.gitignore", "repo/docs/guide.md",
        "fsearch", "fsearch/src", "fsearch/src/main.rs",
        ".hidden", ".hidden/main.rs",
    ]

    private func makeService() -> FileIndexService {
        FileIndexService(
            snapshotURL: root.appendingPathComponent("../\(root.lastPathComponent).bin").standardizedFileURL,
            roots: [root.path],
            exclusions: .standard(home: "/nonexistent-home")
        )
    }

    private func search(_ service: FileIndexService, _ raw: String, limit: Int = 200) throws -> [SearchResult] {
        try XCTUnwrap(service.search(query: FilterGrammar.parse(raw), limit: limit))
    }

    private func relative(_ results: [SearchResult]) -> [String] {
        results.compactMap { $0.path.map { String($0.dropFirst(root.path.count + 1)) } }
    }

    // MARK: Ignore rules

    func testGlobSemantics() {
        func m(_ p: String, _ s: String) -> Bool { GlobMatcher.match(Array(p.utf8), 0, Array(s.utf8), 0) }
        XCTAssertTrue(m("*.log", "app.log"))
        XCTAssertFalse(m("*.log", "src/app.log"))
        XCTAssertTrue(m("**/build", "build"))
        XCTAssertTrue(m("**/build", "a/b/build"))
        XCTAssertTrue(m("a/**/b", "a/b"))
        XCTAssertTrue(m("a/**/b", "a/x/y/b"))
        XCTAssertTrue(m("logs/**", "logs/x/y"))
        XCTAssertTrue(m("file[0-9].txt", "file7.txt"))
        XCTAssertFalse(m("file[!0-9].txt", "file7.txt"))
        XCTAssertTrue(m("?ain.rs", "main.rs"))
    }

    func testIgnoreRuleParsing() throws {
        let rules = IgnoreScope.parse("# comment\n\nbuild/\n!keep.log\n/rootonly.txt\n\\#hash\n")
        XCTAssertEqual(rules.count, 4)
        XCTAssertTrue(rules[0].directoryOnly)
        XCTAssertFalse(rules[0].anchored)
        XCTAssertTrue(rules[1].negated)
        XCTAssertTrue(rules[2].anchored)
        XCTAssertEqual(rules[3].pattern, Array("#hash".utf8))
    }

    // MARK: Matcher

    func testTypoDistanceCountsTranspositionAsOneEdit() throws {
        func distance(_ token: String, _ text: String) throws -> Int {
            let matcher = try XCTUnwrap(TypoMatcher(token: Array(token.utf8)))
            return Array(text.utf8).withUnsafeBufferPointer { matcher.bestDistance(in: $0) }
        }
        XCTAssertEqual(try distance("mian", "main.rs"), 1)
        XCTAssertEqual(try distance("main", "main.rs"), 0)
        XCTAssertEqual(try distance("invoce", "quarterly invoice.pdf"), 1)
        XCTAssertEqual(try distance("shcema", "schema.json"), 1)
        XCTAssertEqual(try distance("readme", "xyz"), 6)
        XCTAssertNil(TypoMatcher(token: Array("abc".utf8)), "under 4 bytes gets no typo budget")
    }

    func testScoreTiersRankExactPrefixSubstringSubsequenceTypo() {
        func score(_ token: String, _ name: String) -> Int32 {
            let t = Array(token.utf8)
            let original = Array(name.utf8)
            let lowered = original.map(FuzzyMatcher.lower)
            let typo = TypoMatcher(token: t)
            return t.withUnsafeBufferPointer { tok in
                lowered.withUnsafeBufferPointer { low in
                    original.withUnsafeBufferPointer { orig in
                        FuzzyMatcher.score(token: tok, lowered: low, original: orig, allowTypos: true, typoMatcher: typo)
                    }
                }
            }
        }
        let exact = score("main.rs", "main.rs")
        let prefix = score("main", "main.rs")
        let word = score("invoice", "Quarterly Invoice.pdf")
        let mid = score("voice", "Quarterly Invoice.pdf")
        let subsequence = score("qinv", "Quarterly Invoice.pdf")
        let typo = score("mian", "main.rs")
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, mid)
        XCTAssertGreaterThan(mid, subsequence)
        XCTAssertGreaterThan(subsequence, typo)
        XCTAssertGreaterThan(typo, 0)
        XCTAssertEqual(score("zzzz", "main.rs"), 0)
        XCTAssertGreaterThan(score("iotr", "IsOffTheRecord.swift"), 0, "camel-case initials")
        XCTAssertEqual(score("summon", "debug_pritam-anurag-basu-hindi-cinema-music-soundtrack-metro.html"), 0,
                       "letters scattered mid-word across a long name do not match")
    }

    // MARK: Crawl recall

    func testCrawlRecallMatchesGroundTruthMinusListedExclusions() throws {
        try makeTree()
        let service = makeService()
        let report = try service.build()
        XCTAssertTrue(report.unreadable.isEmpty)
        let all = try search(service, "kind:file", limit: 1_000) + search(service, "kind:folder", limit: 1_000)
        XCTAssertEqual(Set(relative(all)), expectedRelativePaths)
        // Every expected file must be reachable by a name query (recall), not only by filters.
        for path in expectedRelativePaths {
            let name = (path as NSString).lastPathComponent
            let hits = relative(try search(service, name, limit: 1_000))
            XCTAssertTrue(hits.contains(path), "query '\(name)' missed \(path)")
        }
    }

    func testMtimeMatchesStat() throws {
        try makeTree()
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: root.appendingPathComponent("notes/main.rs").path)
        let service = makeService()
        try service.build()
        let hit = try XCTUnwrap(try search(service, "main.rs in:\(root.path)/notes").first)
        XCTAssertEqual(hit.payload["mtime"], .number(1_600_000_000))
    }

    // MARK: Query behaviour

    func testRankingAndMultiTokenAncestorMatch() throws {
        try makeTree()
        let service = makeService()
        try service.build()

        let typo = relative(try search(service, "mian"))
        XCTAssertTrue(typo.contains("notes/main.rs"), "one transposition still finds main.rs")

        let scoped = relative(try search(service, "fsearch main"))
        XCTAssertEqual(scoped.first, "fsearch/src/main.rs", "second token matches a folder above")

        let all = relative(try search(service, "main.rs"))
        XCTAssertEqual(all.last, ".hidden/main.rs", "hidden folders rank last")

        let invoice = relative(try search(service, "invoice kind:pdf"))
        XCTAssertEqual(invoice, ["notes/Quarterly Invoice.pdf"])
        XCTAssertEqual(relative(try search(service, "kind:image")), ["notes/photo.heic"])
        XCTAssertTrue(try search(service, "main in:\(root.path)/nope").isEmpty)
        XCTAssertTrue(try search(service, "").isEmpty)
    }

    // MARK: Snapshot and changes

    func testSnapshotRoundTrip() throws {
        try makeTree()
        let service = makeService()
        try service.build()
        let reloaded = makeService()
        XCTAssertTrue(try reloaded.load())
        XCTAssertEqual(
            Set(relative(try reloaded.search(query: FilterGrammar.parse("kind:file"), limit: 1_000) ?? [])),
            Set(relative(try search(service, "kind:file", limit: 1_000)))
        )
        let other = FileIndexService(snapshotURL: service.snapshotURL, roots: ["/tmp"], exclusions: .standard())
        XCTAssertFalse(try other.load(), "a snapshot for other roots is not reused")
        try? FileManager.default.removeItem(at: service.snapshotURL)
    }

    func testAppliedChangesAddRemoveAndCompact() throws {
        try makeTree()
        let service = makeService()
        try service.build()
        try touch("notes/brand-new-file.txt")
        try touch("notes/newdir/deep/inner.txt")
        try FileManager.default.removeItem(at: root.appendingPathComponent("notes/photo.heic"))
        service.apply([FileIndexChange(path: root.path + "/notes", recursive: false)], lastEventID: 0)

        XCTAssertEqual(relative(try search(service, "brand-new")), ["notes/brand-new-file.txt"])
        XCTAssertEqual(relative(try search(service, "inner.txt")), ["notes/newdir/deep/inner.txt"])
        XCTAssertTrue(try search(service, "photo").isEmpty)

        try service.saveIfDirty()
        let reloaded = makeService()
        XCTAssertTrue(try reloaded.load())
        XCTAssertEqual(relative(try XCTUnwrap(reloaded.search(query: FilterGrammar.parse("inner.txt"), limit: 10))),
                       ["notes/newdir/deep/inner.txt"])
        try? FileManager.default.removeItem(at: service.snapshotURL)
    }

    func testCatchUpReplaysFSEventsSinceSnapshot() throws {
        try makeTree()
        let service = makeService()
        try service.build()
        try touch("notes/created-while-away.md")
        // FSEvents delivers after its latency window; give the daemon time to log it.
        Thread.sleep(forTimeInterval: 1.5)

        let restarted = makeService()
        XCTAssertTrue(try restarted.load())
        XCTAssertTrue(restarted.catchUp(keepWatching: false, timeout: 10))
        XCTAssertEqual(relative(try XCTUnwrap(restarted.search(query: FilterGrammar.parse("created-while-away"), limit: 10))),
                       ["notes/created-while-away.md"])
        try? FileManager.default.removeItem(at: service.snapshotURL)
    }

    func testIndexedSearchFallsBackUntilLoaded() throws {
        let fallback = FakeSpotlightIndex(files: [SearchResult(id: "file:/x", title: "fallback", kind: .file, path: "/x", score: 1)])
        let adapter = IndexedFileSearch(service: makeService(), fallback: fallback)
        XCTAssertEqual(try adapter.search(query: FilterGrammar.parse("fallback"), limit: 5).map(\.title), ["fallback"])
    }
}
