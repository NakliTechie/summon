import Foundation
import CryptoKit

/// Opt-in fetch of MLX model tree via `huggingface-cli`. Never surprise-downloads.
/// Records/verifies a pin file (`summon.sha256`) over `config.json` after download.
public enum L0ModelFetch {
    public static let pinFileName = "summon.sha256"

    public enum FetchError: Error, LocalizedError {
        case notConsented
        case huggingfaceCLIMissing
        case processFailed(String)
        case hashMismatch(expected: String, actual: String)
        case pinMissing
        case configMissing

        public var errorDescription: String? {
            switch self {
            case .notConsented: return "L0 consent required before fetch (run: ai l0-consent)"
            case .huggingfaceCLIMissing: return "huggingface-cli not found"
            case .processFailed(let s): return s
            case .hashMismatch(let e, let a): return "model pin mismatch expected=\(e) actual=\(a)"
            case .pinMissing: return "summon.sha256 pin missing — re-fetch after consent"
            case .configMissing: return "config.json missing in model directory"
            }
        }
    }

    public static func detectHFCLI() -> String? {
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/huggingface-cli",
            "/opt/homebrew/bin/huggingface-cli",
            "/usr/local/bin/huggingface-cli",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // Absolute which only (no bare PATH binary for security)
        return nil
    }

    /// SHA-256 hex of the model `config.json` (stable, small pin).
    public static func digestConfig(at modelDir: URL) throws -> String {
        let config = modelDir.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: config.path) else {
            throw FetchError.configMissing
        }
        let data = try Data(contentsOf: config)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func writePin(digest: String, modelDir: URL) throws {
        let url = modelDir.appendingPathComponent(pinFileName)
        try Data(digest.utf8).write(to: url, options: .atomic)
    }

    public static func readPin(modelDir: URL) -> String? {
        let url = modelDir.appendingPathComponent(pinFileName)
        guard let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    /// Verify installed tree against pin file and/or manifest expected digest.
    public static func verifyInstalled(modelDir: URL, manifest: L0ModelManifest) throws {
        let actual = try digestConfig(at: modelDir)
        if let pin = readPin(modelDir: modelDir) {
            guard pin == actual else {
                throw FetchError.hashMismatch(expected: pin, actual: actual)
            }
        } else if manifest.hasPendingPin {
            throw FetchError.pinMissing
        }
        if !manifest.hasPendingPin {
            guard actual == manifest.sha256.lowercased() else {
                throw FetchError.hashMismatch(expected: manifest.sha256, actual: actual)
            }
        }
    }

    public static func fetch(rung: L0PackagedModelRung, store: FileL0WeightStore) throws -> URL {
        guard store.consent().granted else { throw FetchError.notConsented }
        let dest = store.container.appendingPathComponent(rung.manifest.modelID, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let cli = detectHFCLI() else { throw FetchError.huggingfaceCLIMissing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        var args = ["download", rung.manifest.hfRepo, "--local-dir", dest.path]
        if let rev = rung.manifest.hfRevision, !rev.isEmpty {
            args.append(contentsOf: ["--revision", rev])
        }
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw FetchError.processFailed(String(e.prefix(300)))
        }
        // Pin after download
        let digest = try digestConfig(at: dest)
        if rung.manifest.hasPendingPin {
            try writePin(digest: digest, modelDir: dest)
        } else {
            guard digest == rung.manifest.sha256.lowercased() else {
                try? FileManager.default.removeItem(at: dest)
                throw FetchError.hashMismatch(expected: rung.manifest.sha256, actual: digest)
            }
            try writePin(digest: digest, modelDir: dest)
        }
        try verifyInstalled(modelDir: dest, manifest: rung.manifest)
        return dest
    }
}
