import Foundation

/// Lifecycle owner for the app-managed SearXNG container (`summon-searxng`).
///
/// Runtime-agnostic over Apple `container` and Docker, always addressing the
/// one container Summon created by name. It never touches a container it did not
/// create, never calls `container system stop` (the runtime is shared with other
/// tools), and never pulls an image or recreates a container: creation stays
/// with `searxng-up.sh`, which the one-consent installer runs.
///
/// Three verbs map to the user's intent:
/// - `reconcile` — on launch or re-enable: restore a stopped instance the user
///   left enabled, with bounded retries. Nothing runs when the preference is off.
/// - `stop` — "Disable": stop the service, keep the container, settings and data.
/// - `remove` — "Remove local backend": delete the container and the recorded
///   URL; image cleanup is opt-in because layers can be shared.
///
/// No network primitive lives here. State comes from the runtime CLI (`inspect`),
/// so the sovereignty inventory of egress files is unchanged.
public struct WebSearchBackend: Sendable {
    public static let containerName = "summon-searxng"
    public static let imageReference = "docker.io/searxng/searxng:latest"

    public enum Runtime: String, Sendable, Equatable {
        case docker
        case container
    }

    /// Observed state of the app-owned container.
    public enum State: Sendable, Equatable {
        /// Neither `docker` nor `container` is installed.
        case noRuntime
        /// A runtime is installed but its daemon/apiserver is not answering.
        case runtimeDown(Runtime)
        /// No container named `summon-searxng` exists on any reachable runtime.
        case missing
        case stopped(Runtime)
        case running(Runtime, hostPort: Int)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    public enum ReconcileOutcome: Sendable, Equatable {
        /// Preference off: nothing inspected, nothing started.
        case preferenceOff
        /// No app-owned container to manage (never set up, or removed).
        case notManaged
        /// A `summon-searxng` exists, but this profile never recorded its URL:
        /// another profile (or a hand-run script under a different HOME) set it
        /// up. Left untouched; running setup from this profile adopts it.
        case notOwned
        case alreadyRunning(baseURL: String)
        case recovered(baseURL: String, attempts: Int)
        case unavailable(reason: String)
        case cancelled
    }

    public struct Outcome: Sendable, Equatable {
        public let ok: Bool
        public let detail: String
        public init(ok: Bool, detail: String) {
            self.ok = ok
            self.detail = detail
        }
    }

    private let runner: any ProcessRunning
    private let locator: any ToolLocating
    private let recordURL: @Sendable (String) -> Void
    private let clearURL: @Sendable () -> Void
    private let recordedURL: @Sendable () -> String?
    private let sleep: @Sendable (Duration) async -> Void

    public init(
        runner: any ProcessRunning,
        locator: any ToolLocating,
        recordURL: @escaping @Sendable (String) -> Void,
        clearURL: @escaping @Sendable () -> Void,
        recordedURL: @escaping @Sendable () -> String?,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.runner = runner
        self.locator = locator
        self.recordURL = recordURL
        self.clearURL = clearURL
        self.recordedURL = recordedURL
        self.sleep = sleep
    }

    /// Real subprocesses, real tool lookup, real discovery file.
    public static func production(timeout: TimeInterval? = 90) -> WebSearchBackend {
        WebSearchBackend(
            runner: SubprocessRunner(timeout: timeout),
            locator: ToolLocator(),
            recordURL: { SearXNGDiscovery.record(baseURL: $0) },
            clearURL: { SearXNGDiscovery.clear() },
            recordedURL: { SearXNGDiscovery.discoveredBaseURL() }
        )
    }

    /// Ownership evidence: only Summon's own setup (the script, or a recovery this
    /// profile performed) writes the recorded URL. The container name is global to
    /// the daemon, so the name alone never proves this profile set it up.
    public var isOwned: Bool { recordedURL() != nil }

    // MARK: - Inspect

    /// Ask each installed runtime whether it holds the app-owned container.
    /// Docker is asked first to match `searxng-up.sh`, which prefers an installed Docker.
    public func inspect() async -> State {
        var sawRuntimeDown: Runtime?
        var sawAnyRuntime = false
        for runtime in [Runtime.docker, .container] {
            guard let tool = locator.locate(runtime.rawValue) else { continue }
            sawAnyRuntime = true
            guard await daemonUp(runtime, tool: tool) else {
                if sawRuntimeDown == nil { sawRuntimeDown = runtime }
                continue
            }
            let result = await runner.run(tool, ["inspect", Self.containerName], env: toolEnv())
            guard result.exitCode == 0 else { continue }
            if let state = Self.parseInspect(runtime: runtime, json: result.output) { return state }
        }
        if !sawAnyRuntime { return .noRuntime }
        if let down = sawRuntimeDown { return .runtimeDown(down) }
        return .missing
    }

    private func daemonUp(_ runtime: Runtime, tool: String) async -> Bool {
        let args = runtime == .docker ? ["info"] : ["system", "status"]
        return await runner.run(tool, args, env: toolEnv()).exitCode == 0
    }

    /// Parse the runtime's `inspect` JSON into a state. Both CLIs return an array
    /// with one object per container; the field paths differ per runtime.
    static func parseInspect(runtime: Runtime, json: String) -> State? {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first else { return nil }
        switch runtime {
        case .container:
            let status = (first["status"] as? [String: Any])?["state"] as? String
            let configuration = first["configuration"] as? [String: Any]
            let ports = configuration?["publishedPorts"] as? [[String: Any]]
            let hostPort = ports?.first.flatMap { $0["hostPort"] as? Int }
            return state(runtime: runtime, running: status == "running", hostPort: hostPort)
        case .docker:
            let status = (first["State"] as? [String: Any])?["Status"] as? String
            let network = first["NetworkSettings"] as? [String: Any]
            let ports = network?["Ports"] as? [String: Any]
            let bindings = ports?["8080/tcp"] as? [[String: Any]]
            let hostPort = bindings?.first.flatMap { ($0["HostPort"] as? String).flatMap(Int.init) }
            // A stopped Docker container reports no live bindings; fall back to the
            // configured port so the recorded URL survives a stop/start cycle.
            let configured = ((first["HostConfig"] as? [String: Any])?["PortBindings"] as? [String: Any])
            let configuredBindings = configured?["8080/tcp"] as? [[String: Any]]
            let configuredPort = configuredBindings?.first
                .flatMap { ($0["HostPort"] as? String).flatMap(Int.init) }
            return state(runtime: runtime, running: status == "running", hostPort: hostPort ?? configuredPort)
        }
    }

    private static func state(runtime: Runtime, running: Bool, hostPort: Int?) -> State {
        guard running else { return .stopped(runtime) }
        return .running(runtime, hostPort: hostPort ?? 8080)
    }

    // MARK: - Reconcile (launch / re-enable)

    /// Restore an enabled backend after a crash, reboot, or runtime restart.
    ///
    /// Only an existing app-owned container is started. Bounded: `attempts`
    /// start attempts with the given `backoff` between them, and the loop exits
    /// early when the surrounding task is cancelled (the user disabled the
    /// feature). The Apple runtime is started once if it is down, but only with
    /// ownership evidence (a recorded URL): a runtime installed for other reasons
    /// is never booted by a launcher whose web search merely defaults to on.
    /// Docker Desktop is a GUI app and is never launched from here.
    public func reconcile(
        enabled: Bool,
        attempts: Int = 3,
        backoff: [Duration] = [.seconds(2), .seconds(5)]
    ) async -> ReconcileOutcome {
        guard enabled else { return .preferenceOff }
        var state = await inspect()
        if isOwned, case .runtimeDown(.container) = state,
           let tool = locator.locate(Runtime.container.rawValue) {
            _ = await runner.run(tool, ["system", "start"], env: toolEnv())
            state = await inspect()
        }
        switch state {
        case .noRuntime:
            return .unavailable(reason: "no container runtime is installed")
        case .runtimeDown(let runtime):
            return .unavailable(reason: "the \(runtime.rawValue) runtime is not running")
        case .missing:
            return .notManaged
        case .running, .stopped:
            // The name is daemon-global; without this profile's recorded URL the
            // container belongs to someone else's setup and is left alone.
            guard isOwned else { return .notOwned }
            if case .running(_, let hostPort) = state {
                let url = Self.baseURL(port: hostPort)
                recordURL(url)
                return .alreadyRunning(baseURL: url)
            }
            guard case .stopped(let runtime) = state else { return .notManaged }
            return await startWithRetries(runtime, attempts: max(1, attempts), backoff: backoff)
        }
    }

    private func startWithRetries(_ runtime: Runtime, attempts: Int, backoff: [Duration]) async -> ReconcileOutcome {
        guard let tool = locator.locate(runtime.rawValue) else {
            return .unavailable(reason: "\(runtime.rawValue) disappeared during recovery")
        }
        var lastDetail = ""
        for attempt in 1...attempts {
            if Task.isCancelled { return .cancelled }
            let started = await runner.run(tool, ["start", Self.containerName], env: toolEnv())
            if started.exitCode == 0, case .running(_, let hostPort) = await inspect() {
                let url = Self.baseURL(port: hostPort)
                recordURL(url)
                return .recovered(baseURL: url, attempts: attempt)
            }
            lastDetail = Self.tail(started.output)
            if attempt < attempts {
                let delay = backoff[min(attempt - 1, max(0, backoff.count - 1))]
                await sleep(delay)
            }
        }
        let suffix = lastDetail.isEmpty ? "" : ": \(lastDetail)"
        return .unavailable(reason: "could not start \(Self.containerName) after \(attempts) attempts\(suffix)")
    }

    // MARK: - Disable / Remove

    /// "Disable": stop the app-owned container, keep it and its data for a fast
    /// re-enable. A missing container is not an error.
    public func stop() async -> Outcome {
        switch await inspect() {
        case .running(let runtime, _):
            guard isOwned else {
                return Outcome(
                    ok: true,
                    detail: "\(Self.containerName) is running but was not set up from this profile; left running"
                )
            }
            guard let tool = locator.locate(runtime.rawValue) else {
                return Outcome(ok: false, detail: "\(runtime.rawValue) not found")
            }
            let result = await runner.run(tool, ["stop", Self.containerName], env: toolEnv())
            guard result.exitCode == 0 else {
                return Outcome(ok: false, detail: "stop failed: \(Self.tail(result.output))")
            }
            return Outcome(ok: true, detail: "stopped \(Self.containerName); container and settings kept")
        case .stopped:
            return Outcome(ok: true, detail: "\(Self.containerName) already stopped")
        case .missing, .noRuntime, .runtimeDown:
            return Outcome(ok: true, detail: "no app-owned backend to stop")
        }
    }

    /// "Remove local backend": delete the app-owned container and the recorded
    /// URL. `purgeImage` also removes the SearXNG image, which is optional because
    /// images and layers can be shared with other containers. Uses the runtime's
    /// own removal commands; never deletes runtime storage directories directly.
    public func remove(purgeImage: Bool) async -> Outcome {
        let state = await inspect()
        var runtime: Runtime?
        switch state {
        case .running(let r, _), .stopped(let r): runtime = r
        case .missing, .noRuntime: runtime = nil
        case .runtimeDown(let r): return Outcome(ok: false, detail: "the \(r.rawValue) runtime is not running")
        }
        if runtime != nil, !isOwned {
            return Outcome(
                ok: false,
                detail: "\(Self.containerName) exists but was not set up from this profile; refusing to remove it. "
                    + "Run searxng-up.sh here first to adopt it, or searxng-down.sh --remove to remove it deliberately."
            )
        }
        clearURL()
        guard let runtime, let tool = locator.locate(runtime.rawValue) else {
            return Outcome(ok: true, detail: "no app-owned backend to remove; recorded URL cleared")
        }
        let removed = await runner.run(tool, ["rm", "-f", Self.containerName], env: toolEnv())
        guard removed.exitCode == 0 else {
            return Outcome(ok: false, detail: "remove failed: \(Self.tail(removed.output))")
        }
        var detail = "removed \(Self.containerName); recorded URL cleared"
        if purgeImage {
            let imageName = runtime == .docker ? "searxng/searxng:latest" : Self.imageReference
            let purged = await runner.run(tool, ["image", "rm", imageName], env: toolEnv())
            detail += purged.exitCode == 0 ? "; image removed" : "; image kept (\(Self.tail(purged.output)))"
        } else {
            detail += "; image kept"
        }
        return Outcome(ok: true, detail: detail)
    }

    // MARK: - Helpers

    static func baseURL(port: Int) -> String { "http://127.0.0.1:\(port)/" }
}

// MARK: - One-line summaries shared by the CLI and the Preferences status row

extension WebSearchBackend.State {
    public var summary: String {
        switch self {
        case .noRuntime: return "no container runtime installed"
        case .runtimeDown(let runtime): return "\(runtime.rawValue) runtime not running"
        case .missing: return "not set up"
        case .stopped(let runtime): return "stopped (\(runtime.rawValue))"
        case .running(let runtime, let hostPort): return "running on 127.0.0.1:\(hostPort) (\(runtime.rawValue))"
        }
    }
}

extension WebSearchBackend.ReconcileOutcome {
    public var summary: String {
        switch self {
        case .preferenceOff: return "web search off; backend left as is"
        case .notManaged: return "no app-owned backend; nothing to restore"
        case .notOwned: return "a summon-searxng exists but this profile did not set it up; left untouched (run setup to adopt it)"
        case .alreadyRunning(let baseURL): return "running at \(baseURL)"
        case .recovered(let baseURL, let attempts): return "restored at \(baseURL) after \(attempts) attempt(s)"
        case .unavailable(let reason): return "unavailable: \(reason)"
        case .cancelled: return "recovery cancelled"
        }
    }
}

extension WebSearchBackend {

    /// Last non-empty lines of a subprocess transcript, bounded for a status line.
    public static func tail(_ output: String, lines: Int = 3, maxLength: Int = 240) -> String {
        let kept = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
            .joined(separator: " | ")
        guard kept.count > maxLength else { return kept }
        return String(kept.suffix(maxLength))
    }

    private func toolEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"].map { $0.isEmpty ? "/usr/bin:/bin" : $0 } ?? "/usr/bin:/bin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + existing
        return env
    }
}
