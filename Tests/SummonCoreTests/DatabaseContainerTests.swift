import XCTest
@testable import SummonCore

/// harden 2026-09-10 F9: an overridden HOME must isolate the store the same way
/// it isolates the recorded SearXNG URL. Application Support resolved through the
/// account home, so a caller who set HOME but not SUMMON_CONTAINER_DIR read and
/// wrote the real user's store.
final class DatabaseContainerTests: XCTestCase {
    private func withEnvironment(_ pairs: [String: String?], _ body: () throws -> Void) rethrows {
        var previous: [String: String?] = [:]
        for (key, value) in pairs {
            previous[key] = ProcessInfo.processInfo.environment[key]
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        try body()
    }

    func testDefaultContainerFollowsHOMEWhenNoOverrideIsSet() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-store-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try withEnvironment(["HOME": home.path, "SUMMON_CONTAINER_DIR": nil]) {
            let container = try SummonDatabase.defaultContainerURL()
            XCTAssertTrue(
                container.path.hasPrefix(home.path),
                "store must live under $HOME (\(home.path)); got \(container.path)"
            )
            XCTAssertEqual(container.lastPathComponent, "Summon")
            XCTAssertTrue(container.path.contains("/Library/Application Support/"))
        }
    }

    func testExplicitOverrideStillWins() throws {
        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-store-override-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: override) }
        try withEnvironment(["HOME": "/nonexistent-home", "SUMMON_CONTAINER_DIR": override.path]) {
            let container = try SummonDatabase.defaultContainerURL()
            XCTAssertEqual(container.standardizedFileURL.path, override.standardizedFileURL.path)
        }
    }
}
