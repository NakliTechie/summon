import XCTest
@testable import SummonCore

/// Live, end-to-end proof of the one-consent install: runs the REAL installer
/// against the repo's searxng-up.sh (reuse Docker, else `container`), confirms it
/// reaches `.enabled` with a loopback SearXNG answering HTTP 200, then tears the
/// instance down. Gated on SUMMON_RUN_WEBSEARCH_LIVE; needs a container runtime.
/// The `enable` step only captures here — it does not touch app settings.
final class WebSearchInstallerLiveTests: XCTestCase {
    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ v: T) { value = v }
    }

    func testRealInstallReachesEnabledAndServesLoopback() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SUMMON_RUN_WEBSEARCH_LIVE"] == "1",
            "Set SUMMON_RUN_WEBSEARCH_LIVE=1 for the live web-search install (needs a container runtime)."
        )
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let upScript = repoRoot.appendingPathComponent("packaging/searxng/searxng-up.sh").path
        let downScript = repoRoot.appendingPathComponent("packaging/searxng/searxng-down.sh").path

        defer { runScript(downScript) } // leave the machine as found

        let enabledURL = Box<String?>(nil)
        let phases = Box<[WebSearchInstaller.Phase]>([])
        let installer = WebSearchInstaller(
            runner: SubprocessRunner(),
            locator: ToolLocator(),
            scriptPath: upScript,
            discover: { SearXNGDiscovery.discoveredBaseURL() },
            enable: { url in enabledURL.value = url }
        )

        let final = await installer.install { phases.value.append($0) }
        print("live install phases: " + phases.value.map { "\($0)" }.joined(separator: " → "))

        guard case .enabled(let url) = final else {
            return XCTFail("expected .enabled, got \(final)")
        }
        XCTAssertEqual(enabledURL.value, url, "enable closure should receive the discovered URL")

        let (_, response) = try await URLSession.shared.data(
            from: XCTUnwrap(URL(string: "\(url)search?q=canberra&format=json"))
        )
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "SearXNG JSON API should answer 200")
    }

    private func runScript(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
