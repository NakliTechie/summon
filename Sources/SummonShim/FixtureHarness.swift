import Foundation
import SummonCore

/// C0 fixture harness: load extension fixtures headlessly via the shim + action bus.
public struct FixtureHarness: Sendable {
    public init() {}

    public struct RunResult: Sendable {
        public let manifest: ExtensionManifest
        public let tree: HostNode
        public let storage: [String: String]
        public let busResults: [ActionResult]
    }

    /// Load manifest JSON + entry JS, render host tree, optionally dispatch a settings action as ext actor.
    public func run(
        manifestJSON: Data,
        entrySource: String,
        core: SummonCore? = nil,
        fetchHandler: ((URL, String, [String: String], String?) throws -> ShimRuntime.FetchResponse)? = nil
    ) throws -> RunResult {
        let manifest = try ManifestGate.decode(from: manifestJSON)
        let runtime = try ShimRuntime(
            manifest: manifest,
            fetchHandler: fetchHandler
        )
        let tree = try runtime.run(entrySource: entrySource)

        var busResults: [ActionResult] = []
        if let core {
            // Prove the extension door hits the same bus (invariant 7) with actor=ext:<id>.
            let result = try core.dispatch(
                action: .settingsSet(
                    key: "ext.\(manifest.extensionID).lastRender",
                    value: .string(tree.type)
                ),
                actor: .ext(id: manifest.extensionID)
            )
            busResults.append(result)
        }

        return RunResult(
            manifest: manifest,
            tree: tree,
            storage: runtime.storageSnapshot(),
            busResults: busResults
        )
    }
}
