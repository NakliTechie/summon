import Darwin
import XCTest
@testable import SummonAI

final class BoundedProcessRunnerTests: XCTestCase {
    func testRunnerDrainsStandardOutputAndErrorConcurrently() throws {
        let script = try makeScript(
            body: "dd if=/dev/zero bs=1024 count=128 2>/dev/null; "
                + "dd if=/dev/zero bs=1024 count=64 2>/dev/null | cat >&2"
        )
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let result = try BoundedProcessRunner.run(
            executableURL: script,
            arguments: [],
            timeout: 2,
            maximumStandardOutputBytes: 200_000,
            maximumStandardErrorBytes: 100_000
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput.count, 128 * 1_024)
        XCTAssertEqual(result.standardError.count, 64 * 1_024)
        XCTAssertFalse(result.standardOutputTruncated)
        XCTAssertFalse(result.standardErrorTruncated)
    }

    func testRunnerTerminatesAfterTimeout() throws {
        let script = try makeScript(body: "sleep 2")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        XCTAssertThrowsError(
            try BoundedProcessRunner.run(
                executableURL: script,
                arguments: [],
                timeout: 0.1
            )
        ) { error in
            guard case BoundedProcessError.timedOut = error else {
                return XCTFail("expected timeout, received \(error)")
            }
        }
    }

    func testRunnerTerminatesDescendantsAfterTimeout() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-process-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let childPID = directory.appendingPathComponent("child-pid")
        let grandchildPID = directory.appendingPathComponent("grandchild-pid")
        let leafPID = directory.appendingPathComponent("leaf-pid")
        let ready = directory.appendingPathComponent("ready")
        let script = try makeScript(
            body: "child_pidfile=$1; grandchild_pidfile=$2; leaf_pidfile=$3; ready=$4; "
                + "( trap '' TERM; "
                + "/bin/sh -c 'trap \"\" TERM; printf \"%s\" \"$$\" > \"$1\"; "
                + "/bin/sleep 30 & printf \"%s\" \"$!\" > \"$2\"; wait' "
                + "helper \"$grandchild_pidfile\" \"$leaf_pidfile\" & wait ) & child=$!; "
                + "printf '%s' \"$child\" > \"$child_pidfile\"; "
                + "while [ ! -s \"$grandchild_pidfile\" ] || [ ! -s \"$leaf_pidfile\" ]; "
                + "do /bin/sleep 0.01; done; printf ready > \"$ready\"; wait"
        )
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        XCTAssertThrowsError(
            try BoundedProcessRunner.run(
                executableURL: script,
                arguments: [childPID.path, grandchildPID.path, leafPID.path, ready.path],
                timeout: 1.5
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))

        let recordedPIDs = try [childPID, grandchildPID, leafPID].map(readPID(from:))
        defer {
            for pid in recordedPIDs {
                Darwin.kill(pid, SIGKILL)
            }
        }
        for pid in recordedPIDs {
            XCTAssertTrue(
                waitForProcessExit(pid, timeout: 2),
                "descendant \(pid) remained after the runner timed out"
            )
        }
    }

    private func readPID(from url: URL) throws -> pid_t {
        let raw = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(raw), "missing PID in \(url.lastPathComponent)")
    }

    private func waitForProcessExit(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            errno = 0
            if Darwin.kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }

    private func makeScript(body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("helper.sh")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}
