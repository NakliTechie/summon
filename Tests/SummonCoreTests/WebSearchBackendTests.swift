import XCTest
@testable import SummonCore

/// The app-owned SearXNG lifecycle over a scripted runtime CLI. Every test pins a
/// command sequence: the backend may only inspect, start, stop, or remove the one
/// container it owns, never pull, create, or stop the shared runtime.
final class WebSearchBackendTests: XCTestCase {
    // MARK: - Doubles

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ v: T) { value = v }
    }

    final class MockLocator: ToolLocating, @unchecked Sendable {
        let available: Set<String>
        init(_ available: Set<String>) { self.available = available }
        func locate(_ tool: String) -> String? {
            available.contains(tool) ? "/opt/homebrew/bin/\(tool)" : nil
        }
    }

    /// Scripted runner: `respond` maps a (tool, args) call to an outcome and may
    /// mutate shared state so later inspects see the effect of earlier starts.
    final class MockRunner: ProcessRunning, @unchecked Sendable {
        struct Call: Equatable { let tool: String; let args: [String] }
        private let lock = NSLock()
        private var calls: [Call] = []
        var respond: @Sendable (Call) -> ProcessOutcome = { _ in ProcessOutcome(exitCode: 0) }
        func run(_ executable: String, _ args: [String], env: [String: String]) async -> ProcessOutcome {
            let call = Call(tool: (executable as NSString).lastPathComponent, args: args)
            lock.lock(); calls.append(call); lock.unlock()
            return respond(call)
        }
        var recorded: [Call] { lock.lock(); defer { lock.unlock() }; return calls }
        func count(_ tool: String, _ prefix: [String]) -> Int {
            recorded.filter { $0.tool == tool && Array($0.args.prefix(prefix.count)) == prefix }.count
        }
    }

    static let containerRunning = """
    [{"configuration":{"id":"summon-searxng","publishedPorts":[{"hostAddress":"127.0.0.1","hostPort":8123,
    "containerPort":8080,"proto":"tcp"}]},"status":{"state":"running","networks":[]}}]
    """
    static let containerStopped = """
    [{"configuration":{"id":"summon-searxng","publishedPorts":[{"hostAddress":"127.0.0.1","hostPort":8123,
    "containerPort":8080,"proto":"tcp"}]},"status":{"state":"stopped"}}]
    """
    static let dockerRunning = """
    [{"State":{"Status":"running"},"HostConfig":{"PortBindings":{"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"8091"}]}},
    "NetworkSettings":{"Ports":{"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"8091"}]}}}]
    """
    static let dockerStopped = """
    [{"State":{"Status":"exited"},"HostConfig":{"PortBindings":{"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"8091"}]}},
    "NetworkSettings":{"Ports":{}}}]
    """

    /// `recordedURL` is the ownership evidence: the default models a profile whose
    /// own setup recorded the backend; pass nil for a profile that never set it up.
    private func makeBackend(
        runner: MockRunner,
        tools: Set<String>,
        recorded: Box<[String]> = Box([]),
        cleared: Box<Int> = Box(0),
        slept: Box<[Duration]> = Box([]),
        recordedURL: String? = "http://127.0.0.1:8123/",
        onSleep: @escaping @Sendable () -> Void = {}
    ) -> WebSearchBackend {
        WebSearchBackend(
            runner: runner,
            locator: MockLocator(tools),
            recordURL: { recorded.value.append($0) },
            clearURL: { cleared.value += 1 },
            recordedURL: { recordedURL },
            sleep: { slept.value.append($0); onSleep() }
        )
    }

    /// Apple-runtime world: docker absent, apiserver up, container state scripted.
    private func containerWorld(state: Box<String>, startExit: Box<[Int32]> = Box([])) -> MockRunner {
        let runner = MockRunner()
        runner.respond = { call in
            switch (call.tool, call.args) {
            case ("container", ["system", "status"]): return ProcessOutcome(exitCode: 0)
            case ("container", ["inspect", "summon-searxng"]):
                switch state.value {
                case "running": return ProcessOutcome(exitCode: 0, output: Self.containerRunning)
                case "stopped": return ProcessOutcome(exitCode: 0, output: Self.containerStopped)
                default: return ProcessOutcome(exitCode: 1, output: "not found")
                }
            case ("container", ["start", "summon-searxng"]):
                let code = startExit.value.isEmpty ? 0 : startExit.value.removeFirst()
                if code == 0 { state.value = "running" }
                return ProcessOutcome(exitCode: code, output: code == 0 ? "" : "boot failed: kernel panic\nretry later")
            case ("container", ["stop", "summon-searxng"]):
                state.value = "stopped"; return ProcessOutcome(exitCode: 0)
            case ("container", ["rm", "-f", "summon-searxng"]):
                state.value = "missing"; return ProcessOutcome(exitCode: 0)
            default: return ProcessOutcome(exitCode: 0)
            }
        }
        return runner
    }

    // MARK: - Parsing

    func testParseContainerInspectRunningAndStopped() {
        XCTAssertEqual(
            WebSearchBackend.parseInspect(runtime: .container, json: Self.containerRunning),
            .running(.container, hostPort: 8123)
        )
        XCTAssertEqual(
            WebSearchBackend.parseInspect(runtime: .container, json: Self.containerStopped),
            .stopped(.container)
        )
        XCTAssertNil(WebSearchBackend.parseInspect(runtime: .container, json: "not json"))
    }

    func testParseDockerInspectRunningAndStopped() {
        XCTAssertEqual(
            WebSearchBackend.parseInspect(runtime: .docker, json: Self.dockerRunning),
            .running(.docker, hostPort: 8091)
        )
        XCTAssertEqual(
            WebSearchBackend.parseInspect(runtime: .docker, json: Self.dockerStopped),
            .stopped(.docker)
        )
    }

    // MARK: - Inspect

    func testInspectReportsNoRuntimeWhenNeitherToolExists() async {
        let runner = MockRunner()
        let backend = makeBackend(runner: runner, tools: [])
        let state = await backend.inspect()
        XCTAssertEqual(state, .noRuntime)
        XCTAssertTrue(runner.recorded.isEmpty)
    }

    func testInspectReportsRuntimeDownWhenApiserverIsNotAnswering() async {
        let runner = MockRunner()
        runner.respond = { call in
            call.args == ["system", "status"] ? ProcessOutcome(exitCode: 1) : ProcessOutcome(exitCode: 0)
        }
        let backend = makeBackend(runner: runner, tools: ["container"])
        let state = await backend.inspect()
        XCTAssertEqual(state, .runtimeDown(.container))
        XCTAssertEqual(runner.count("container", ["inspect"]), 0, "no inspect against a down runtime")
    }

    func testInspectReportsMissingWhenNoRuntimeHoldsTheContainer() async {
        let runner = MockRunner()
        runner.respond = { call in
            call.args.first == "inspect" ? ProcessOutcome(exitCode: 1, output: "No such object") : ProcessOutcome(exitCode: 0)
        }
        let backend = makeBackend(runner: runner, tools: ["docker", "container"])
        let state = await backend.inspect()
        XCTAssertEqual(state, .missing)
        XCTAssertEqual(runner.count("docker", ["inspect"]), 1)
        XCTAssertEqual(runner.count("container", ["inspect"]), 1)
    }

    // MARK: - Reconcile

    func testReconcilePreferenceOffTouchesNothing() async {
        let runner = MockRunner()
        let backend = makeBackend(runner: runner, tools: ["docker", "container"])
        let outcome = await backend.reconcile(enabled: false)
        XCTAssertEqual(outcome, .preferenceOff)
        XCTAssertTrue(runner.recorded.isEmpty, "a disabled preference must not even inspect")
    }

    func testReconcileMissingContainerIsNotManagedAndNeverCreates() async {
        let state = Box("missing")
        let runner = containerWorld(state: state)
        let backend = makeBackend(runner: runner, tools: ["container"])
        let outcome = await backend.reconcile(enabled: true)
        XCTAssertEqual(outcome, .notManaged)
        XCTAssertEqual(runner.count("container", ["start"]), 0)
        XCTAssertEqual(runner.count("container", ["run"]), 0)
        XCTAssertEqual(runner.count("container", ["image"]), 0)
    }

    func testReconcileRunningContainerRecordsURLWithoutStarting() async {
        let recorded = Box<[String]>([])
        let runner = containerWorld(state: Box("running"))
        let backend = makeBackend(runner: runner, tools: ["container"], recorded: recorded)
        let outcome = await backend.reconcile(enabled: true)
        XCTAssertEqual(outcome, .alreadyRunning(baseURL: "http://127.0.0.1:8123/"))
        XCTAssertEqual(recorded.value, ["http://127.0.0.1:8123/"])
        XCTAssertEqual(runner.count("container", ["start"]), 0)
    }

    func testReconcileStoppedContainerStartsAndRecordsURL() async {
        let recorded = Box<[String]>([])
        let runner = containerWorld(state: Box("stopped"))
        let backend = makeBackend(runner: runner, tools: ["container"], recorded: recorded)
        let outcome = await backend.reconcile(enabled: true)
        XCTAssertEqual(outcome, .recovered(baseURL: "http://127.0.0.1:8123/", attempts: 1))
        XCTAssertEqual(recorded.value, ["http://127.0.0.1:8123/"])
        XCTAssertEqual(runner.count("container", ["start", "summon-searxng"]), 1)
    }

    func testReconcileRetriesWithBackoffThenSucceeds() async {
        let slept = Box<[Duration]>([])
        let runner = containerWorld(state: Box("stopped"), startExit: Box([1, 1, 0]))
        let backend = makeBackend(runner: runner, tools: ["container"], slept: slept)
        let outcome = await backend.reconcile(enabled: true)
        XCTAssertEqual(outcome, .recovered(baseURL: "http://127.0.0.1:8123/", attempts: 3))
        XCTAssertEqual(runner.count("container", ["start"]), 3)
        XCTAssertEqual(slept.value, [.seconds(2), .seconds(5)], "backoff between attempts, none after success")
    }

    func testReconcileGivesUpAfterBoundedAttemptsAndKeepsLogTail() async {
        let runner = containerWorld(state: Box("stopped"), startExit: Box([1, 1, 1, 1, 1]))
        let backend = makeBackend(runner: runner, tools: ["container"])
        let outcome = await backend.reconcile(enabled: true)
        guard case .unavailable(let reason) = outcome else { return XCTFail("expected unavailable, got \(outcome)") }
        XCTAssertTrue(reason.contains("after 3 attempts"), reason)
        XCTAssertTrue(reason.contains("kernel panic"), "reason carries the runtime's output tail: \(reason)")
        XCTAssertEqual(runner.count("container", ["start"]), 3, "bounded: exactly the configured attempts")
        XCTAssertEqual(runner.count("container", ["rm"]), 0, "recovery never deletes the container")
    }

    func testReconcileStartsAppleRuntimeOnceWhenDown() async {
        let apiserverUp = Box(false)
        let runner = MockRunner()
        runner.respond = { call in
            switch call.args {
            case ["system", "status"]: return ProcessOutcome(exitCode: apiserverUp.value ? 0 : 1)
            case ["system", "start"]: apiserverUp.value = true; return ProcessOutcome(exitCode: 0)
            case ["inspect", "summon-searxng"]: return ProcessOutcome(exitCode: 0, output: Self.containerRunning)
            default: return ProcessOutcome(exitCode: 0)
            }
        }
        let backend = makeBackend(runner: runner, tools: ["container"])
        let outcome = await backend.reconcile(enabled: true)
        XCTAssertEqual(outcome, .alreadyRunning(baseURL: "http://127.0.0.1:8123/"))
        XCTAssertEqual(runner.count("container", ["system", "start"]), 1)
        XCTAssertEqual(runner.count("container", ["system", "stop"]), 0)
    }

    func testReconcileLeavesADownAppleRuntimeAloneWithoutOwnershipEvidence() async {
        // Web search defaults to on, so a runtime installed for other reasons must
        // not be booted by a launcher that never set a backend up.
        let runner = MockRunner()
        runner.respond = { call in
            call.args == ["system", "status"] ? ProcessOutcome(exitCode: 1) : ProcessOutcome(exitCode: 0)
        }
        let backend = makeBackend(runner: runner, tools: ["container"], recordedURL: nil)
        let outcome = await backend.reconcile(enabled: true)
        XCTAssertEqual(outcome, .unavailable(reason: "the container runtime is not running"))
        XCTAssertEqual(runner.count("container", ["system", "start"]), 0)
    }

    // MARK: - Ownership (harden 2026-09-10 F6)
    // The container name is daemon-global. A profile that never recorded the URL
    // (an isolated HOME, a test, an agent) must not start, stop, or remove a
    // backend some other profile set up.

    func testReconcileWithoutOwnershipLeavesAStoppedContainerAlone() async {
        let state = Box("stopped")
        let runner = containerWorld(state: state)
        let backend = makeBackend(runner: runner, tools: ["container"], recordedURL: nil)
        let outcome = await backend.reconcile(enabled: true)
        XCTAssertEqual(outcome, .notOwned)
        XCTAssertEqual(runner.count("container", ["start"]), 0)
        XCTAssertEqual(state.value, "stopped")
    }

    func testStopWithoutOwnershipLeavesTheBackendRunning() async {
        let state = Box("running")
        let runner = containerWorld(state: state)
        let backend = makeBackend(runner: runner, tools: ["container"], recordedURL: nil)
        let outcome = await backend.stop()
        XCTAssertTrue(outcome.ok, outcome.detail)
        XCTAssertTrue(outcome.detail.contains("not set up from this profile"), outcome.detail)
        XCTAssertEqual(runner.count("container", ["stop"]), 0)
        XCTAssertEqual(state.value, "running")
    }

    func testRemoveWithoutOwnershipRefuses() async {
        let cleared = Box(0)
        let state = Box("running")
        let runner = containerWorld(state: state)
        let backend = makeBackend(runner: runner, tools: ["container"], cleared: cleared, recordedURL: nil)
        let outcome = await backend.remove(purgeImage: true)
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.detail.contains("not set up from this profile"), outcome.detail)
        XCTAssertEqual(runner.count("container", ["rm"]), 0)
        XCTAssertEqual(runner.count("container", ["image"]), 0)
        XCTAssertEqual(cleared.value, 0)
        XCTAssertEqual(state.value, "running")
    }

    func testReconcileNeverLaunchesDockerDesktop() async {
        let runner = MockRunner()
        runner.respond = { call in
            call.args == ["info"] ? ProcessOutcome(exitCode: 1, output: "Cannot connect to the Docker daemon") : ProcessOutcome(exitCode: 0)
        }
        let backend = makeBackend(runner: runner, tools: ["docker"])
        let outcome = await backend.reconcile(enabled: true)
        XCTAssertEqual(outcome, .unavailable(reason: "the docker runtime is not running"))
        XCTAssertEqual(runner.recorded.map(\.args), [["info"]], "only the daemon probe ran")
    }

    func testReconcileStopsRetryingWhenCancelled() async {
        let runner = containerWorld(state: Box("stopped"), startExit: Box([1, 1, 1]))
        let backend = makeBackend(
            runner: runner, tools: ["container"],
            onSleep: { withUnsafeCurrentTask { $0?.cancel() } }
        )
        let outcome = await Task { await backend.reconcile(enabled: true) }.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(runner.count("container", ["start"]), 1, "no further attempts after cancellation")
    }

    // MARK: - Disable / Remove

    func testStopOnlyStopsARunningOwnedContainer() async {
        let state = Box("running")
        let runner = containerWorld(state: state)
        let backend = makeBackend(runner: runner, tools: ["container"])
        let outcome = await backend.stop()
        XCTAssertTrue(outcome.ok, outcome.detail)
        XCTAssertEqual(runner.count("container", ["stop", "summon-searxng"]), 1)
        XCTAssertEqual(runner.count("container", ["rm"]), 0, "disable keeps the container")
        XCTAssertEqual(runner.count("container", ["system", "stop"]), 0, "never stops the shared runtime")
        XCTAssertEqual(state.value, "stopped")
    }

    func testStopWithoutAnOwnedContainerIsANoOp() async {
        let runner = containerWorld(state: Box("missing"))
        let backend = makeBackend(runner: runner, tools: ["container"])
        let outcome = await backend.stop()
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(runner.count("container", ["stop"]), 0)
    }

    func testRemoveDeletesContainerClearsURLAndKeepsImageByDefault() async {
        let cleared = Box(0)
        let state = Box("stopped")
        let runner = containerWorld(state: state)
        let backend = makeBackend(runner: runner, tools: ["container"], cleared: cleared)
        let outcome = await backend.remove(purgeImage: false)
        XCTAssertTrue(outcome.ok, outcome.detail)
        XCTAssertEqual(runner.count("container", ["rm", "-f", "summon-searxng"]), 1)
        XCTAssertEqual(runner.count("container", ["image"]), 0)
        XCTAssertEqual(cleared.value, 1)
        XCTAssertEqual(state.value, "missing")
        XCTAssertTrue(outcome.detail.contains("image kept"))
    }

    func testRemoveWithPurgeImageUsesTheRuntimeImageCommand() async {
        let runner = containerWorld(state: Box("running"))
        let backend = makeBackend(runner: runner, tools: ["container"])
        let outcome = await backend.remove(purgeImage: true)
        XCTAssertTrue(outcome.ok, outcome.detail)
        XCTAssertEqual(runner.count("container", ["image", "rm", WebSearchBackend.imageReference]), 1)
        XCTAssertTrue(outcome.detail.contains("image removed"))
    }

    func testRemoveWhenRuntimeIsDownFailsWithoutTouchingStorage() async {
        let cleared = Box(0)
        let runner = MockRunner()
        runner.respond = { call in
            call.args == ["system", "status"] ? ProcessOutcome(exitCode: 1) : ProcessOutcome(exitCode: 0)
        }
        let backend = makeBackend(runner: runner, tools: ["container"], cleared: cleared)
        let outcome = await backend.remove(purgeImage: true)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(cleared.value, 0, "the recorded URL stays until the container is actually gone")
        XCTAssertEqual(runner.count("container", ["rm"]), 0)
    }

    // MARK: - Tail

    func testTailKeepsLastNonEmptyLinesBounded() {
        let output = "step 1\n\nstep 2\n   \nstep 3\nstep 4\n"
        XCTAssertEqual(WebSearchBackend.tail(output), "step 2 | step 3 | step 4")
        XCTAssertEqual(WebSearchBackend.tail(""), "")
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(WebSearchBackend.tail(long).count, 240)
    }
}
