import XCTest
@testable import SummonCore

final class WebSearchInstallerTests: XCTestCase {
    // MARK: - Test doubles

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ v: T) { value = v }
    }

    final class MockLocator: ToolLocating, @unchecked Sendable {
        private let lock = NSLock()
        private var available: Set<String>
        init(_ available: Set<String>) { self.available = available }
        func add(_ tool: String) { lock.lock(); available.insert(tool); lock.unlock() }
        func locate(_ tool: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return available.contains(tool) ? "/opt/homebrew/bin/\(tool)" : nil
        }
    }

    final class MockRunner: ProcessRunning, @unchecked Sendable {
        struct Call: Sendable { let exe: String; let args: [String]; let env: [String: String] }
        private let lock = NSLock()
        private(set) var calls: [Call] = []
        var outcomeFor: @Sendable (Call) -> ProcessOutcome = { _ in ProcessOutcome(exitCode: 0) }
        var onRun: @Sendable (Call) -> Void = { _ in }
        func run(_ executable: String, _ args: [String], env: [String: String]) async -> ProcessOutcome {
            let call = Call(exe: executable, args: args, env: env)
            lock.lock(); calls.append(call); lock.unlock()
            onRun(call)
            return outcomeFor(call)
        }
        var recorded: [Call] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    private func makeInstaller(
        runner: MockRunner,
        locator: MockLocator,
        discover: @escaping @Sendable () -> String? = { "http://127.0.0.1:8080/" },
        enable: @escaping @Sendable (String) throws -> Void = { _ in }
    ) -> WebSearchInstaller {
        WebSearchInstaller(
            runner: runner, locator: locator,
            scriptPath: "/opt/summon/searxng-up.sh",
            discover: discover, enable: enable
        )
    }

    private func collectPhases(
        _ installer: WebSearchInstaller
    ) async -> [WebSearchInstaller.Phase] {
        let phases = Box<[WebSearchInstaller.Phase]>([])
        _ = await installer.install { phases.value.append($0) }
        return phases.value
    }

    // MARK: - Tests

    func testDockerPresentSkipsRuntimeInstallAndEnables() async {
        let runner = MockRunner()
        let enabled = Box<String?>(nil)
        let installer = makeInstaller(
            runner: runner, locator: MockLocator(["docker"]),
            enable: { enabled.value = $0 }
        )
        let phases = await collectPhases(installer)
        XCTAssertEqual(phases, [.detecting, .preparing, .verifying, .enabled(baseURL: "http://127.0.0.1:8080/")])
        XCTAssertEqual(enabled.value, "http://127.0.0.1:8080/")
        // No `brew install` when a runtime already exists.
        XCTAssertFalse(runner.recorded.contains { $0.args.contains("install") })
    }

    func testNoRuntimeButBrewInstallsContainerThenEnables() async {
        let locator = MockLocator(["brew"])
        let runner = MockRunner()
        runner.onRun = { call in
            if call.args.contains("install"), call.args.contains("container") { locator.add("container") }
        }
        let installer = makeInstaller(runner: runner, locator: locator)
        let phases = await collectPhases(installer)
        XCTAssertEqual(
            phases,
            [.detecting, .installingRuntime, .preparing, .verifying, .enabled(baseURL: "http://127.0.0.1:8080/")]
        )
        XCTAssertTrue(runner.recorded.contains { $0.args == ["install", "container"] })
    }

    func testNoRuntimeAndNoBrewAsksToInstallRuntime() async {
        let installer = makeInstaller(runner: MockRunner(), locator: MockLocator([]))
        let phases = await collectPhases(installer)
        XCTAssertEqual(phases.first, .detecting)
        guard case .needsRuntime = phases.last else {
            return XCTFail("expected needsRuntime, got \(String(describing: phases.last))")
        }
    }

    func testBringUpFailureIsTerminalFailure() async {
        let runner = MockRunner()
        runner.outcomeFor = { call in
            call.exe == "/bin/bash" ? ProcessOutcome(exitCode: 1) : ProcessOutcome(exitCode: 0)
        }
        let installer = makeInstaller(runner: runner, locator: MockLocator(["docker"]))
        let phases = await collectPhases(installer)
        XCTAssertEqual(phases.first, .detecting)
        guard case .failed = phases.last else {
            return XCTFail("expected failed, got \(String(describing: phases.last))")
        }
    }

    func testUnreachableAfterBringUpFails() async {
        let installer = makeInstaller(
            runner: MockRunner(), locator: MockLocator(["docker"]),
            discover: { nil }
        )
        let phases = await collectPhases(installer)
        guard case .failed = phases.last else {
            return XCTFail("expected failed when discovery is nil, got \(String(describing: phases.last))")
        }
    }

    func testBringUpRunsWithHomebrewOnPath() async {
        // Regression for the GUI-subprocess PATH gotcha: a launched .app must add
        // Homebrew's bin so docker/container/brew resolve for the script's children.
        let runner = MockRunner()
        let installer = makeInstaller(runner: runner, locator: MockLocator(["docker"]))
        _ = await collectPhases(installer)
        let bash = runner.recorded.first { $0.exe == "/bin/bash" }
        XCTAssertNotNil(bash)
        XCTAssertTrue(
            (bash?.env["PATH"] ?? "").contains("/opt/homebrew/bin"),
            "script PATH must include Homebrew bin; got \(bash?.env["PATH"] ?? "nil")"
        )
    }

    func testSettingFailureIsTerminalFailure() async {
        struct EnableError: Error {}
        let installer = makeInstaller(
            runner: MockRunner(), locator: MockLocator(["docker"]),
            enable: { _ in throw EnableError() }
        )
        let phases = await collectPhases(installer)
        guard case .failed = phases.last else {
            return XCTFail("expected failed when enable throws, got \(String(describing: phases.last))")
        }
    }
}
