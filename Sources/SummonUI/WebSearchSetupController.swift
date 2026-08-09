#if canImport(AppKit)
import AppKit
import SummonCore

/// UI-side owner of the one-consent web-search install: builds the real
/// `WebSearchInstaller`, runs it off the main actor, and reports each phase back
/// on the main actor. The launcher stays fully interactive throughout — nothing
/// here blocks. Reused by onboarding and Preferences.
@MainActor
public final class WebSearchSetupController {
    private let core: SummonCore
    private let scriptPath: String
    private var running = false
    public private(set) var lastPhase: WebSearchInstaller.Phase?

    public init(core: SummonCore, scriptPath: String) {
        self.core = core
        self.scriptPath = scriptPath
    }

    /// Whether full web search is already enabled (persisted).
    public var isEnabled: Bool {
        ((try? core.settings.get("web.search.enabled")) ?? nil)?.boolValue == true
    }

    /// Start the install. `onPhase` fires on the main actor for every transition;
    /// idempotent while a run is in flight.
    public func enableWebSearch(onPhase: @escaping @MainActor (WebSearchInstaller.Phase) -> Void) {
        guard !running else { return }
        running = true
        let core = self.core
        let installer = WebSearchInstaller(
            runner: SubprocessRunner(),
            locator: ToolLocator(),
            scriptPath: scriptPath,
            discover: { SearXNGDiscovery.discoveredBaseURL() },
            enable: { url in
                _ = try core.dispatch(action: .webConfigSet(enabled: true, baseURL: url), actor: .user)
            }
        )
        Task { [weak self] in
            _ = await installer.install { phase in
                Task { @MainActor in
                    self?.lastPhase = phase
                    onPhase(phase)
                }
            }
            await MainActor.run { [weak self] in self?.running = false }
        }
    }
}
#endif
