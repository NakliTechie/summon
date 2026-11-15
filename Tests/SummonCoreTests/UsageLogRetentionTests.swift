import XCTest
@testable import SummonCore

/// The usage log keeps 30 days (Chirag, 2026-11-02: "drop anything older than 30 days").
final class UsageLogRetentionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("usagelog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func line(_ event: String, _ time: String) -> String {
        #"{"event":"\#(event)","process":"test","t":"\#(time)"}"#
    }

    func testDropsLinesOlderThanTheCutoffAndTornLines() throws {
        let file = directory.appendingPathComponent("usage.jsonl")
        let text = [
            line("old", "2026-10-01T09:00:00.000+05:30"),
            line("edge", "2026-10-16T12:00:00.000+05:30"),
            #"{"event":"torn","t":"2026-11-1"#,
            line("new", "2026-11-15T16:00:00.000+05:30"),
        ].joined(separator: "\n") + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let cutoff = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-16T06:30:00Z")) // 12:00 IST
        UsageLog.prune(fileAt: file, olderThan: cutoff)
        let kept = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(kept, [line("edge", "2026-10-16T12:00:00.000+05:30"), line("new", "2026-11-15T16:00:00.000+05:30")])
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600, "the pruned file stays owner-only")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".prune"))
    }

    func testDeletesAFileWithNothingRecent() throws {
        let file = directory.appendingPathComponent("usage.1.jsonl")
        try (line("old", "2026-09-01T09:00:00.000+05:30") + "\n").write(to: file, atomically: true, encoding: .utf8)
        UsageLog.prune(fileAt: file, olderThan: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLeavesARecentFileUntouched() throws {
        let file = directory.appendingPathComponent("usage.jsonl")
        let text = line("new", "2026-11-15T16:00:00.000+05:30") + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        UsageLog.prune(fileAt: file, olderThan: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, before)
    }
}
