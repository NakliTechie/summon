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
            return fail("Web search backend didn't start.", progress)
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
public struct ToolLocator: ToolLocating {
    private let dirs: [String]
    public init(dirs: [String] = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]) {
        self.dirs = dirs
    }

    public func locate(_ tool: String) -> String? {
        for dir in dirs {
            let path = dir + "/" + tool
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

/// Runs a subprocess to completion, capturing merged stdout/stderr.
public struct SubprocessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: String, _ args: [String], env: [String: String]) async -> ProcessOutcome {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: ProcessOutcome(exitCode: finished.terminationStatus, output: text))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: ProcessOutcome(exitCode: -1, output: error.localizedDescription))
            }
        }
    }
}
