import Foundation

/// D7 interim decision: ride a user-managed `mlx_lm.generate` process until an
/// embedded runtime lands. Summon detects it, but never installs or daemonizes it.
///
/// Does **not** auto-download models. Weights path = local HF-style directory
/// (or MLX-converted tree) under Application Support after consent fetch.
public struct MLXProcessL0Engine: L0InferenceEngine, Sendable {
    public let generateBinary: String
    public let maxTokens: Int
    public let systemPrompt: String
    public let timeout: TimeInterval

    public static let trustedBinaryPaths = [
        "/Library/Frameworks/Python.framework/Versions/3.12/bin/mlx_lm.generate",
        "/opt/homebrew/bin/mlx_lm.generate",
        "/usr/local/bin/mlx_lm.generate",
    ]

    public init(
        generateBinary: String,
        maxTokens: Int = 256,
        systemPrompt: String = "You are Summon's on-device sidecar. Be concise. Stage, never claim execution.",
        timeout: TimeInterval = 120
    ) {
        self.generateBinary = generateBinary
        self.maxTokens = maxTokens
        self.systemPrompt = systemPrompt
        self.timeout = timeout
    }

    /// Absolute paths only — no PATH/`env` resolution (supply-chain hardening).
    public static func detectBinary() -> String? {
        for path in trustedBinaryPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    public func isReady(weightsURL: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: weightsURL.path, isDirectory: &isDir)
        guard exists, isDir.boolValue else { return false }
        // Require config.json so empty dirs are not "ready".
        let config = weightsURL.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: config.path)
    }

    public func complete(prompt: String, weightsURL: URL) async throws -> String {
        guard Self.trustedBinaryPaths.contains(generateBinary),
              FileManager.default.isExecutableFile(atPath: generateBinary) else {
            throw ModelRungError.generationFailed(
                "trusted mlx_lm.generate unavailable — install mlx-lm at a supported absolute path"
            )
        }
        guard isReady(weightsURL: weightsURL) else {
            throw ModelRungError.generationFailed("MLX model directory not ready: \(weightsURL.path)")
        }

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let text = try Self.runGenerate(
                        engine: self,
                        modelPath: weightsURL.path,
                        prompt: prompt
                    )
                    cont.resume(returning: text)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func runGenerate(
        engine: MLXProcessL0Engine,
        modelPath: String,
        prompt: String
    ) throws -> String {
        guard trustedBinaryPaths.contains(engine.generateBinary) else {
            throw ModelRungError.generationFailed("MLX binary is outside the trusted absolute-path allowlist")
        }
        let result: BoundedProcessResult
        do {
            result = try BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: engine.generateBinary),
                arguments: [
                    "--model", modelPath,
                    "--system-prompt", engine.systemPrompt,
                    "--prompt", prompt,
                    "--max-tokens", String(engine.maxTokens),
                    "--temp", "0.2",
                ],
                timeout: engine.timeout
            )
        } catch {
            throw ModelRungError.generationFailed(error.localizedDescription)
        }
        let stdout = String(data: result.standardOutput, encoding: .utf8) ?? ""
        let stderr = String(data: result.standardError, encoding: .utf8) ?? ""
        if result.terminationStatus != 0 {
            throw ModelRungError.generationFailed(
                "mlx_lm exited \(result.terminationStatus): \(stderr.prefix(400))"
            )
        }
        guard !result.standardOutputTruncated else {
            throw ModelRungError.generationFailed("mlx_lm output exceeded the 2 MiB response limit")
        }
        let cleaned = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw ModelRungError.generationFailed("mlx_lm returned empty output")
        }
        return cleaned
    }
}
