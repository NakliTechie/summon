import Foundation
import SummonCore

/// `summon web remove|status`: the app-owned SearXNG lifecycle verbs that go
/// beyond the preference flip. Both run through `WebSearchBackend`, so the CLI
/// and the Preferences pane share one implementation and one vocabulary.
extension SummonCLI {
    /// Persist web search off with no provider URL, then delete the app-owned
    /// container. `--purge-image` also removes the SearXNG image. Under an agent
    /// actor the setting change stages and nothing is removed.
    static func cli_webRemoveCommand(_ args: [String], core: SummonCore) throws {
        let purgeImage = args.contains("--purge-image")
        core.webConfig.enabled = false
        core.webConfig.baseURL = ""
        let result = try core.persistWebConfig(actor: cliActor)
        guard result.isApplied else { exitForOutcome(result) }
        let removed = try awaitOrRun { await WebSearchBackend.production().remove(purgeImage: purgeImage) }
        guard removed.ok else {
            fputs("error: web backend not removed; \(removed.detail)\n", stderr)
            exit(1)
        }
        print("ok web backend removed; \(removed.detail)")
    }

    /// Read-only: the persisted preference beside the observed backend state.
    static func cli_webStatusCommand(core: SummonCore) throws {
        let state = try awaitOrRun { await WebSearchBackend.production().inspect() }
        let recorded = SearXNGDiscovery.discoveredBaseURL() ?? "-"
        let baseURL = core.webConfig.baseURL.isEmpty ? "-" : core.webConfig.baseURL
        print("enabled=\(core.webConfig.enabled) baseURL=\(baseURL)")
        print("backend=\(state.summary) recordedURL=\(recorded)")
    }
}
