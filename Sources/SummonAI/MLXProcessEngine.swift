import Foundation

/// D7 decision (Chirag 2026-08-04): **MLX** for L0 — via `mlx_lm.generate` process bridge
/// until pure mlx-swift LLM packaging is clean. Detects binary; fails loud if missing.
///
/// Does **not** auto-download models. Weights path = local HF-style directory
/// (or MLX-converted tree) under Application Support after consent fetch.
public struct MLXProcessL0Engine: L0InferenceEngine, Sendable {
    public var generateBinary: String
    public var maxTokens: Int
    public var systemPrompt: String

    public init(
        generateBinary: String = MLXProcessL0Engine.detectBinary() ?? "mlx_lm.generate",
        maxTokens: Int = 256,
        systemPrompt: String = "You are Summon's on-device sidecar. Be concise. Stage, never claim execution."
    ) {
        self.generateBinary = generateBinary
        self.maxTokens = maxTokens
        self.systemPrompt = systemPrompt
    }

    public static func detectBinary() -> String? {
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/mlx_lm.generate",
            "/opt/homebrew/bin/mlx_lm.generate",
            "/usr/local/bin/mlx_lm.generate",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // PATH lookup
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["mlx_lm.generate"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) {
            return s
        }
        return nil
    }

    public func isReady(weightsURL: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: weightsURL.path, isDirectory: &isDir)
        // MLX models are directories; also accept a marker file for tests.
        if exists && isDir.boolValue { return true }
        if exists && weightsURL.pathExtension == "gguf" {
            // Wrong format for MLX process engine
            return false
        }
        // Marker for Fake-compatible local test dirs
        let config = weightsURL.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: config.path)
    }

    public func complete(prompt: String, weightsURL: URL) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: generateBinary)
                || generateBinary == "mlx_lm.generate" else {
            throw ModelRungError.generationFailed(
                "mlx_lm.generate not found — install mlx-lm (D7 MLX path)"
            )
        }
        guard isReady(weightsURL: weightsURL) else {
            throw ModelRungError.generationFailed("MLX model directory not ready: \(weightsURL.path)")
        }

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let text = try Self.runGenerate(
                        binary: self.generateBinary,
                        modelPath: weightsURL.path,
                        system: self.systemPrompt,
                        prompt: prompt,
                        maxTokens: self.maxTokens
                    )
                    cont.resume(returning: text)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func runGenerate(
        binary: String,
        modelPath: String,
        system: String,
        prompt: String,
        maxTokens: Int
    ) throws -> String {
        let process = Process()
        // Prefer absolute binary; else rely on PATH via /usr/bin/env
        if binary.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = [
                "--model", modelPath,
                "--system-prompt", system,
                "--prompt", prompt,
                "--max-tokens", String(maxTokens),
                "--temp", "0.2",
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                binary,
                "--model", modelPath,
                "--system-prompt", system,
                "--prompt", prompt,
                "--max-tokens", String(maxTokens),
                "--temp", "0.2",
            ]
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ModelRungError.generationFailed("mlx_lm spawn failed: \(error.localizedDescription)")
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw ModelRungError.generationFailed(
                "mlx_lm exited \(process.terminationStatus): \(stderr.prefix(400))"
            )
        }
        let cleaned = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw ModelRungError.generationFailed("mlx_lm returned empty output")
        }
        return cleaned
    }
}
