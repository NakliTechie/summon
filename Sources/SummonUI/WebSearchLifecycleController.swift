#if canImport(AppKit)
import AppKit
import SummonCore

/// UI-side owner of the app-managed SearXNG lifecycle: reconciles the user's
/// persisted preference with the observed container state at launch and on
/// re-enable, stops the service on disable, and removes it on request. Runs the
/// `WebSearchBackend` off the main actor; publishes a one-line status on the
/// main actor for the Preferences row and the launcher footer.
///
/// Cancellation: disabling or removing cancels an in-flight recovery, so a
/// backend the user has turned off is never restarted by a stale task.
@MainActor
public final class WebSearchLifecycleController {
    public enum Status: Equatable {
        case unknown
        case checking
        case restoring
        case running(baseURL: String)
        case stopped
        case notSetUp
        case unavailable(String)

        public var text: String {
            switch self {
            case .unknown: return ""
            case .checking: return "Checking web search backend…"
            case .restoring: return "Restoring web search…"
            case .running(let baseURL): return "Local backend: running at \(baseURL)"
            case .stopped: return "Local backend: stopped (disable keeps its data; enable restarts it)"
            case .notSetUp: return "Local backend: not set up"
            case .unavailable(let reason): return "Local backend: \(reason)"
            }
        }

        /// Transient phases worth showing in the launcher footer.
        public var isTransient: Bool {
            switch self {
            case .checking, .restoring: return true
            default: return false
            }
        }
    }

    private let core: SummonCore
    private let backend: WebSearchBackend
    private var task: Task<Void, Never>?
    private var observers: [(Status) -> Void] = []
    public private(set) var status: Status = .unknown {
        didSet { observers.forEach { $0(status) } }
    }

    public init(core: SummonCore, backend: WebSearchBackend = .production()) {
        self.core = core
        self.backend = backend
    }

    public func observe(_ observer: @escaping @MainActor (Status) -> Void) {
        observers.append(observer)
        observer(status)
    }

    private var preferenceEnabled: Bool {
        ((try? core.settings.get("web.search.enabled")) ?? nil)?.boolValue == true
    }

    /// Launch and re-enable: restore a stopped backend the user left enabled.
    /// A disabled preference inspects nothing.
    public func reconcileIfEnabled() {
        guard preferenceEnabled else {
            refreshStatus()
            return
        }
        task?.cancel()
        status = .restoring
        let backend = self.backend
        // A recorded URL exists only when Summon's own setup ran; without it the
        // Apple runtime is never booted on the user's behalf.
        let managed = SearXNGDiscovery.discoveredBaseURL() != nil
        task = Task { [weak self] in
            let outcome = await backend.reconcile(enabled: true, startRuntimeIfDown: managed)
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch outcome {
                case .preferenceOff, .cancelled: break
                case .notManaged: self.status = .notSetUp
                case .alreadyRunning(let baseURL), .recovered(let baseURL, _): self.status = .running(baseURL: baseURL)
                case .unavailable(let reason): self.status = .unavailable(reason)
                }
            }
        }
    }

    /// Preference toggle: on restores, off stops (container and data kept).
    public func setEnabled(_ enabled: Bool) {
        if enabled {
            reconcileIfEnabled()
            return
        }
        task?.cancel()
        status = .checking
        let backend = self.backend
        task = Task { [weak self] in
            let outcome = await backend.stop()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.status = outcome.ok ? .stopped : .unavailable(outcome.detail)
            }
        }
    }

    /// "Remove local backend": persists web search off with no provider URL, then
    /// deletes the app-owned container (and, on request, its image).
    public func removeBackend(purgeImage: Bool, completion: @escaping @MainActor (WebSearchBackend.Outcome) -> Void) {
        task?.cancel()
        core.webConfig.enabled = false
        core.webConfig.baseURL = ""
        guard let result = try? core.persistWebConfig(actor: .user), result.isApplied else {
            completion(WebSearchBackend.Outcome(ok: false, detail: "web search setting was not applied"))
            return
        }
        status = .checking
        let backend = self.backend
        task = Task { [weak self] in
            let outcome = await backend.remove(purgeImage: purgeImage)
            await MainActor.run { [weak self] in
                self?.status = outcome.ok ? .notSetUp : .unavailable(outcome.detail)
                completion(outcome)
            }
        }
    }

    /// Inspect only; never starts or stops anything.
    public func refreshStatus() {
        let backend = self.backend
        Task { [weak self] in
            let state = await backend.inspect()
            await MainActor.run { [weak self] in
                // An in-flight restore/stop/remove owns the status until it lands.
                guard let self, !self.status.isTransient else { return }
                switch state {
                case .running(_, let hostPort): self.status = .running(baseURL: "http://127.0.0.1:\(hostPort)/")
                case .stopped: self.status = .stopped
                case .missing: self.status = .notSetUp
                case .noRuntime, .runtimeDown: self.status = .unavailable(state.summary)
                }
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}
#endif
