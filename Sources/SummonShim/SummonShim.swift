import Foundation
import SummonCore

/// Raycast-extension shim (chunk 2 / C0).
///
/// **D2 decision (JSC-first):** JavaScriptCore hosts each extension in its own
/// context. Node builtins and filesystem `require` fail loud. Real store
/// extensions that need full Node APIs may force a D2 revisit — evidence in
/// `NAKLITECHIE-PROJECT-STATE.md`.
public enum SummonShim {
    public static let status = "c0-spike"
    public static let jsRuntime = "JavaScriptCore"

    /// Schema version for extension manifests.
    public static let manifestSchemaVersion = ManifestGate.schemaVersion
}
