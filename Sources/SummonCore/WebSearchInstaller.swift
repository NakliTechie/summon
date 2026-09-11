import Foundation

/// One-consent, background installer for full web search (opt-in SearXNG).
///
/// A single user action ("turn on web search") runs this to completion with no
/// further steps: reuse Docker if it's already installed, otherwise pull Apple's
/// `container` runtime via Homebrew, then the SearXNG image, start it loopback-only,
/// and flip the setting on. Never blocks the launcher — the caller runs it off the
/// main actor and observes `Phase`. The runtime is only ever installed on this
/// explicit consent (a package-manager user's deliberate opt-in); Summon never
/// installs one silently or on launch.
public struct WebSearchInstaller: Sendable {
    public enum Phase: Sendable, Equatable {
        case detecting
        case installingRuntime              // pulling Apple `container` via Homebrew
        case preparing                      // pulling the SearXNG image + starting it
        case verifying
        case enabled(baseURL: String)
        case needsRuntime(hint: String)     // no runtime and no Homebrew to get one
        case failed(reason: String)

        public var isTerminal: Bool {
            switch self {
            case .enabled, .needsRuntime, .failed: return true
            default: return false
            }
        }
    }

    private let runner: any ProcessRunning
    private let locator: any ToolLocating
    private let scriptPath: String
    private let discover: @Sendable () -> String?
    private let enable: @Sendable (String) throws -> Void

    public init(
        runner: any ProcessRunning,
        locator: any ToolLocating,
        scriptPath: String,
        discover: @escaping @Sendable () -> String?,
        enable: @escaping @Sendable (String) throws -> Void
    ) {
        self.runner = runner
        self.locator = locator
        self.scriptPath = scriptPath
        self.discover = discover
        self.enable = enable
    }

    /// Run the whole enable flow. Reports each transition through `progress` and
    /// returns the terminal phase. Never throws — failures are terminal phases.
    @discardableResult
    public func install(progress: @Sendable (Phase) -> Void) async -> Phase {
        progress(.detecting)
        // Reuse an installed Docker (or an already-present container) before pulling
        // anything: "if docker not available already, then container gets pulled."
        let hasRuntime = locator.locate("docker") != nil || locator.locate("container") != nil
        if !hasRuntime {
            guard let brew = locator.locate("brew") else {
                let hint = "Full web search needs Docker or Apple's container. "
                    + "Install Docker, or Homebrew then `brew install container`."
                progress(.needsRuntime(hint: hint))
                return .needsRuntime(hint: hint)
            }
            progress(.installingRuntime)
            let installed = await runner.run(brew, ["install", "container"], env: toolEnv())
            guard installed.exitCode == 0, locator.locate("container") != nil else {
                return fail("Couldn't install the container runtime.", progress)
            }
        }

        // The bundled searxng-up.sh owns the verified plumbing: pick the runtime,
        // start it (container guest kernel included), pull the image, run it
        // loopback-only, health-check, and record the URL. Give it a GUI-safe PATH.
        progress(.preparing)
        let up = await runner.run("/bin/bash", [scriptPath], env: toolEnv())
        guard up.exitCode == 0 else {
            // Keep the script's last lines: they name the failing step and the
            // `container logs` / `docker logs` tail it printed, so the user is
            // not left with a bare "didn't start".
            let detail = WebSearchBackend.tail(up.output)
            let reason = detail.isEmpty
                ? "Web search backend didn't start."
                : "Web search backend didn't start: \(detail)"
            return fail(reason, progress)
        }

        progress(.verifying)
        guard let baseURL = discover() else {
            return fail("Web search backend started but wasn't reachable.", progress)
        }
        do {
            try enable(baseURL)
        } catch {
            return fail("Couldn't save the web-search setting.", progress)
        }
        progress(.enabled(baseURL: baseURL))
        return .enabled(baseURL: baseURL)
    }

    private func fail(_ reason: String, _ progress: @Sendable (Phase) -> Void) -> Phase {
        progress(.failed(reason: reason))
        return .failed(reason: reason)
    }

    /// A GUI-launched .app inherits a minimal PATH (`/usr/bin:/bin`), not Homebrew's
    /// bin. Prepend the common tool dirs so `brew`/`docker`/`container` resolve when
    /// the script (and its children) run.
    private func toolEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extras = "/opt/homebrew/bin:/usr/local/bin"
        let existing = env["PATH"].map { $0.isEmpty ? "/usr/bin:/bin" : $0 } ?? "/usr/bin:/bin"
        env["PATH"] = extras + ":" + existing
        return env
    }
}

// MARK: - Injectable process + tool location (mockable in tests)

public struct ProcessOutcome: Sendable, Equatable {
    public let exitCode: Int32
    public let output: String
    public init(exitCode: Int32, output: String = "") {
        self.exitCode = exitCode
        self.output = output
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: String, _ args: [String], env: [String: String]) async -> ProcessOutcome
}

public protocol ToolLocating: Sendable {
    /// Absolute path to `tool`, or nil if not found on the known tool dirs.
    func locate(_ tool: String) -> String?
}

/// Locates CLIs across the dirs a GUI app doesn't get on its PATH by default.
///
/// `SUMMON_TOOL_DIRS` (colon-separated) replaces the search list. It is the seam
/// that lets `make cli-e2e` point the lifecycle at a scripted `docker` and drive
/// the paused / unstartable / recorded-URL paths black-box, without a daemon.
public struct ToolLocator: ToolLocating {
    public static let defaultDirs = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
    private let dirs: [String]
    public init(dirs: [String]? = nil) {
        if let dirs {
            self.dirs = dirs
        } else if let override = ProcessInfo.processInfo.environment["SUMMON_TOOL_DIRS"], !override.isEmpty {
            self.dirs = override.split(separator: ":").map(String.init)
        } else {
            self.dirs = Self.defaultDirs
        }
    }

    public func locate(_ tool: String) -> String? {
        for dir in dirs {
            let path = dir + "/" + tool
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

/// Single mutable slot shared between the launch path and the termination handler.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Append-only byte buffer shared between the pipe reader and the completion path.
private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

/// Runs a subprocess to completion, capturing merged stdout/stderr.
///
/// The pipe is drained concurrently while the child runs, so a child that prints
/// more than the pipe buffer (log tails, verbose runtimes) cannot block on write
/// and deadlock against a reader that only starts after exit. An optional
/// `timeout` terminates a hung child and reports exit code -1.
public struct SubprocessRunner: ProcessRunning {
    private let timeout: TimeInterval?

    public init(timeout: TimeInterval? = nil) {
        self.timeout = timeout
    }

    public func run(_ executable: String, _ args: [String], env: [String: String]) async -> ProcessOutcome {
        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            // Completion rides on Foundation's termination handler, set before run().
            // `waitUntilExit` on a worker thread was observed parked forever for a
            // child that had already exited and been reaped (sampled live: the
            // reconcile sat ten minutes in -[NSConcreteTask waitUntilExit]).
            let buffer = LockedBuffer()
            let drained = DispatchGroup()
            let watchdogBox = LockedBox<DispatchWorkItem?>(nil)
            process.terminationHandler = { finished in
                watchdogBox.value?.cancel()
                // Give the reader a moment to reach EOF; if a grandchild still holds
                // the pipe, return with what was captured so far.
                _ = drained.wait(timeout: .now() + 2)
                var text = String(data: buffer.snapshot(), encoding: .utf8) ?? ""
                var code = finished.terminationStatus
                if finished.terminationReason == .uncaughtSignal, let timeout {
                    text += "\n(timed out after \(Int(timeout))s)"
                    code = -1
                }
                continuation.resume(returning: ProcessOutcome(exitCode: code, output: text))
            }
            drained.enter()
            do {
                try process.run()
            } catch {
                drained.leave()
                continuation.resume(returning: ProcessOutcome(exitCode: -1, output: error.localizedDescription))
                return
            }
            let watchdog: DispatchWorkItem? = timeout.map { seconds in
                let item = DispatchWorkItem {
                    guard process.isRunning else { return }
                    process.terminate()
                    // A child that ignores SIGTERM (or is stuck in the kernel) still
                    // has to die, or the timeout is only advisory.
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
                return item
            }
            watchdogBox.value = watchdog
            // Drain concurrently in chunks. Completion is keyed to the CHILD's exit,
            // not to EOF on the pipe: a grandchild that inherited the pipe (Docker
            // Desktop's CLI helper, a backgrounded job) would otherwise keep this
            // call blocked for its whole lifetime.
            DispatchQueue.global(qos: .utility).async {
                let reader = pipe.fileHandleForReading
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                }
                drained.leave()
            }
        }
    }
}
