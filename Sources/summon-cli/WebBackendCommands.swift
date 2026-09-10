import Foundation
import SummonCore

/// `summon web remove|status`: the app-owned SearXNG lifecycle verbs that go
/// beyond the preference flip. Both run through `WebSearchBackend`, so the CLI
/// and the Preferences pane share one implementation and one vocabulary.
extension SummonCLI {
    /// The production backend, with its health probe journaled through this core.
    static func webBackend(core: SummonCore) -> WebSearchBackend {
        WebSearchBackend.production(healthCheck: { url in
            await WebSearchHealth.check(baseURL: url, core: core, actor: cliActor)
        })
    }

    /// harden F1 (2026-09-10): unknown flags and extra tokens on the lifecycle verbs
    /// are rejected, never ignored — a mistyped `--purge-image` must not silently
    /// keep the image. `search` and `answer` take free text and are not checked here.
    static func cli_rejectUnknownWebArguments(sub: String, rest: [String]) {
        switch sub {
        case "enable", "disable", "status":
            guard rest.isEmpty else {
                fputs("error: summon web \(sub) takes no arguments (got: \(rest.joined(separator: " ")))\n", stderr)
                exit(2)
            }
        case "remove":
            if let unknown = rest.first(where: { $0 != "--purge-image" }) {
                fputs("error: unknown option '\(unknown)' for summon web remove (allowed: --purge-image)\n", stderr)
                exit(2)
            }
        default:
            break
        }
    }

    /// Persist web search off with no provider URL, then delete the app-owned
    /// container. `--purge-image` also removes the SearXNG image. Under an agent
    /// actor the setting change stages and nothing is removed.
    static func cli_webRemoveCommand(_ args: [String], core: SummonCore) throws {
        let purgeImage = args.contains("--purge-image")
        // B12: a runtime that is down cannot honor the removal; fail before the
        // preference changes so the user is not left "off" with a backend still on disk.
        if case .runtimeDown(let runtime) = try awaitOrRun({ await webBackend(core: core).inspect() }) {
            fputs("error: web backend not removed; the \(runtime.rawValue) runtime is not running\n", stderr)
            exit(1)
        }
        core.webConfig.enabled = false
        core.webConfig.baseURL = ""
        let result = try core.persistWebConfig(actor: cliActor)
        guard result.isApplied else { exitForOutcome(result) }
        let removed = try awaitOrRun { await webBackend(core: core).remove(purgeImage: purgeImage) }
        guard removed.ok else {
            fputs("error: web backend not removed; \(removed.detail)\n", stderr)
            exit(1)
        }
        print("ok web backend removed; \(removed.detail)")
    }

    /// Read-only: the persisted preference beside the observed backend state.
    static func cli_webStatusCommand(core: SummonCore) throws {
        let backend = webBackend(core: core)
        let state = try awaitOrRun { await backend.inspect() }
        let recorded = SearXNGDiscovery.discoveredBaseURL() ?? "-"
        let baseURL = core.webConfig.baseURL.isEmpty ? "-" : core.webConfig.baseURL
        // `owned` is the ownership evidence: only this profile's recorded URL lets
        // enable/disable/remove act on the daemon-global container.
        let owned: String
        switch state {
        case .running, .stopped: owned = backend.isOwned ? "yes" : "no"
        default: owned = "-"
        }
        print("enabled=\(core.webConfig.enabled) baseURL=\(baseURL)")
        print("backend=\(state.summary) recordedURL=\(recorded) owned=\(owned)")
    }
}
