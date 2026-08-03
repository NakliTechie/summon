import Foundation

/// Opt-in fetch of MLX model tree via `huggingface-cli`. Never surprise-downloads.
public enum L0ModelFetch {
    public enum FetchError: Error, LocalizedError {
        case notConsented
        case huggingfaceCLIMissing
        case processFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notConsented: return "L0 consent required before fetch"
            case .huggingfaceCLIMissing: return "huggingface-cli not found"
            case .processFailed(let s): return s
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
        return nil
    }

    public static func fetch(rung: L0PackagedModelRung, store: FileL0WeightStore) throws -> URL {
        guard store.consent().granted else { throw FetchError.notConsented }
        let dest = store.container.appendingPathComponent(rung.manifest.modelID, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let cli = detectHFCLI() else { throw FetchError.huggingfaceCLIMissing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["download", rung.manifest.hfRepo, "--local-dir", dest.path]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw FetchError.processFailed(String(e.prefix(300)))
        }
        return dest
    }
}
