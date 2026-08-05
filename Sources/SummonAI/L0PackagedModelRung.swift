import Foundation

/// Experimental L0 using a user-managed local MLX runtime.
///
/// **D7 (Chirag 2026-08-04): MLX** via `mlx_lm.generate` process bridge
/// (`MLXProcessL0Engine`). Weights = HF-style directory under Models/, never in cask.
/// Fallback fleet: L1 unavailable (8GB / no Apple Intelligence) → L0 after consent.
public struct L0ModelManifest: Sendable, Hashable, Codable, Equatable {
    public struct Artifact: Sendable, Hashable, Codable, Equatable {
        public enum Role: String, Sendable, Hashable, Codable {
            case metadata
            case tokenizer
            case weight
        }

        public let path: String
        public let byteCount: Int64
        public let sha256: String
        public let role: Role

        public init(path: String, byteCount: Int64, sha256: String, role: Role) {
            self.path = path
            self.byteCount = byteCount
            self.sha256 = sha256.lowercased()
            self.role = role
        }
    }

    public let modelID: String
    public let displayName: String
    public let quant: String
    public let minRAMGB: Int
    public let approxDownloadBytes: Int64
    /// Hugging Face repo id for MLX community models (fetch lands with consent).
    public let hfRepo: String
    /// Immutable, full-length Hugging Face commit.
    public let hfRevision: String
    /// Every inference-critical file, including every weight shard.
    public let artifacts: [Artifact]
    /// Upstream license identifier surfaced for consent and diagnostics.
    public let license: String

    public init(
        modelID: String,
        displayName: String,
        quant: String,
        minRAMGB: Int,
        approxDownloadBytes: Int64,
        hfRepo: String,
        hfRevision: String,
        artifacts: [Artifact],
        license: String
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.quant = quant
        self.minRAMGB = minRAMGB
        self.approxDownloadBytes = approxDownloadBytes
        self.hfRepo = hfRepo
        self.hfRevision = hfRevision
        self.artifacts = artifacts
        self.license = license
    }

    public static let e2bDefault = L0ModelManifest(
        modelID: "gemma-2-2b-it-4bit",
        displayName: "Gemma 2 2B Instruct (MLX 4-bit)",
        quant: "4bit",
        minRAMGB: 8,
        approxDownloadBytes: 1_492_850_373,
        hfRepo: "mlx-community/gemma-2-2b-it-4bit",
        hfRevision: "2c715097ff9c081a6ac1e5cd239e2ac756b5bd99",
        artifacts: [
            Artifact(
                path: "config.json", byteCount: 982,
                sha256: "41c1077a8a8b14f3e016c0000365aae99fb9eb128596c8378a178f717dca1640",
                role: .metadata
            ),
            Artifact(
                path: "model.safetensors", byteCount: 1_470_988_882,
                sha256: "f87c0f8cfa7bea0d01266bd04fae9b60babfa21a57eefbbaf5354321a0dabbf2",
                role: .weight
            ),
            Artifact(
                path: "model.safetensors.index.json", byteCount: 46_678,
                sha256: "cb1ab8d56b40451421668d828f8650cbf17c2d901d6f43a16f9a0f3ab49e42c9",
                role: .metadata
            ),
            Artifact(
                path: "special_tokens_map.json", byteCount: 555,
                sha256: "db82f8bd9b25d14f9c788e6bde64de84d42f1c2538f1c245ba6cb3e872d14b18",
                role: .tokenizer
            ),
            Artifact(
                path: "tokenizer.json", byteCount: 17_525_357,
                sha256: "3f289bc05132635a8bc7aca7aa21255efd5e18f3710f43e3cdb96bcd41be4922",
                role: .tokenizer
            ),
            Artifact(
                path: "tokenizer.model", byteCount: 4_241_003,
                sha256: "61a7b147390c64585d6c3543dd6fc636906c9af3865a5548f27f31aee1d4c8e2",
                role: .tokenizer
            ),
            Artifact(
                path: "tokenizer_config.json", byteCount: 46_916,
                sha256: "f3a9ecd05833ba49de8432fff27b66bb061ad6a69d17df158de03dc07420e02a",
                role: .tokenizer
            ),
        ],
        license: "gemma"
    )

    public static let e4bOptional = L0ModelManifest(
        modelID: "gemma-2-9b-it-4bit",
        displayName: "Gemma 2 9B Instruct (MLX 4-bit, ≥16GB)",
        quant: "4bit",
        minRAMGB: 16,
        approxDownloadBytes: 5_217_086_795,
        hfRepo: "mlx-community/gemma-2-9b-it-4bit",
        hfRevision: "ff12eb39da2cd9b3b0f4b4f9ffb274603f05bb29",
        artifacts: [
            Artifact(
                path: "config.json", byteCount: 993,
                sha256: "3b821ec4de220f280b933ad4ae3fcec37eac558e35dc26c5963b5039eb81e550",
                role: .metadata
            ),
            Artifact(
                path: "model.safetensors", byteCount: 5_199_450_666,
                sha256: "48a7ecf7042ed2be8de55f9db624ef25848874a516e4080d29b0db35f4ec2a2c",
                role: .weight
            ),
            Artifact(
                path: "model.safetensors.index.json", byteCount: 75_366,
                sha256: "ea25cc56620a9975028634746236dda5b1dff1a079134931e116d5ebbbc1f513",
                role: .metadata
            ),
            Artifact(
                path: "special_tokens_map.json", byteCount: 636,
                sha256: "baec30ea10906f16adb8c18af7a34023002c1746542612b8b41c9f09e1351351",
                role: .tokenizer
            ),
            Artifact(
                path: "tokenizer.json", byteCount: 17_518_525,
                sha256: "7da53ca29fb16f6b2489482fc0bc6a394162cdab14d12764a1755ebc583fea79",
                role: .tokenizer
            ),
            Artifact(
                path: "tokenizer_config.json", byteCount: 40_609,
                sha256: "133af30b591c8b76e1fc15598e5f75423ef451af7d914dbb351cce84ed874312",
                role: .tokenizer
            ),
        ],
        license: "gemma"
    )
}

public struct L0Consent: Sendable, Hashable, Codable, Equatable {
    public var granted: Bool
    public var modelID: String
    public var grantedAt: Date?

    public init(
        granted: Bool = false,
        modelID: String = L0ModelManifest.e2bDefault.modelID,
        grantedAt: Date? = nil
    ) {
        self.granted = granted
        self.modelID = modelID
        self.grantedAt = grantedAt
    }
}

public protocol L0WeightStore: Sendable {
    var requiresInstalledManifestVerification: Bool { get }
    func consent() -> L0Consent
    func setConsent(_ consent: L0Consent) throws
    func weightsPresent(for modelID: String) -> Bool
    func weightsURL(for modelID: String) -> URL?
}

public extension L0WeightStore {
    var requiresInstalledManifestVerification: Bool { true }
}

public struct FileL0WeightStore: L0WeightStore, Sendable {
    public let container: URL

    public init(container: URL? = nil) throws {
        if let container {
            self.container = container
        } else {
            self.container = try SummonCorePaths.modelsDirectory()
        }
        try FileManager.default.createDirectory(at: self.container, withIntermediateDirectories: true)
    }

    private var consentURL: URL { container.appendingPathComponent("l0-consent.json") }

    public func consent() -> L0Consent {
        guard let data = try? Data(contentsOf: consentURL),
              let c = try? JSONDecoder().decode(L0Consent.self, from: data) else {
            return L0Consent()
        }
        return c
    }

    public func setConsent(_ consent: L0Consent) throws {
        let data = try JSONEncoder().encode(consent)
        try data.write(to: consentURL, options: .atomic)
    }

    public func weightsPresent(for modelID: String) -> Bool {
        weightsURL(for: modelID) != nil
    }

    /// MLX model directory: `Models/<modelID>/` with config.json
    public func weightsURL(for modelID: String) -> URL? {
        let dir = container.appendingPathComponent(modelID, isDirectory: true)
        let config = dir.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: config.path) {
            return dir
        }
        return nil
    }
}

public protocol L0InferenceEngine: Sendable {
    func isReady(weightsURL: URL) -> Bool
    func complete(prompt: String, weightsURL: URL) async throws -> String
}

/// Production stand-in when MLX binary is absent — never fabricates completions.
public struct UnavailableL0InferenceEngine: L0InferenceEngine, Sendable {
    public let reason: String
    public init(reason: String = "mlx_lm.generate not installed") {
        self.reason = reason
    }

    public func isReady(weightsURL: URL) -> Bool { false }

    public func complete(prompt: String, weightsURL: URL) async throws -> String {
        throw ModelRungError.unavailable(.l0Packaged, reason)
    }
}

public enum MachineMemory {
    public static func totalRAMGB() -> Int {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &size, &len, nil, 0) == 0 else { return 0 }
        return Int(size / 1_073_741_824)
    }

    public static func recommendedL0Manifest() -> L0ModelManifest {
        totalRAMGB() >= 16 ? .e4bOptional : .e2bDefault
    }
}

public struct L0PackagedModelRung: ModelRung, Sendable {
    public let id: ModelRungID = .l0Packaged
    public let displayName = "Experimental local MLX (L0)"
    public let store: any L0WeightStore
    public let engine: any L0InferenceEngine
    public let manifest: L0ModelManifest

    public init(
        store: any L0WeightStore,
        engine: any L0InferenceEngine,
        manifest: L0ModelManifest = MachineMemory.recommendedL0Manifest()
    ) {
        self.store = store
        self.manifest = manifest
        self.engine = engine
    }

    /// Interim production adapter: a user-managed MLX process only. Never installs
    /// a runtime, starts a daemon, or fabricates completions when unavailable.
    public static func production(
        store: any L0WeightStore,
        manifest: L0ModelManifest = MachineMemory.recommendedL0Manifest()
    ) -> L0PackagedModelRung {
        if let binary = MLXProcessL0Engine.detectBinary() {
            return L0PackagedModelRung(
                store: store,
                engine: MLXProcessL0Engine(generateBinary: binary),
                manifest: manifest
            )
        }
        return L0PackagedModelRung(
            store: store,
            engine: UnavailableL0InferenceEngine(),
            manifest: manifest
        )
    }

    public func availability() async -> RungAvailability {
        if engine is UnavailableL0InferenceEngine {
            return .unavailable(reason: "mlx_lm.generate not installed")
        }
        let c = store.consent()
        guard c.granted, c.modelID == manifest.modelID else {
            let mb = manifest.approxDownloadBytes / 1_000_000
            return .unavailable(
                reason: "consent required (\(mb) MB \(manifest.displayName), license \(manifest.license), via MLX)"
            )
        }
        guard store.weightsPresent(for: manifest.modelID) else {
            return .unavailable(reason: "weights not installed for \(manifest.modelID)")
        }
        guard let url = store.weightsURL(for: manifest.modelID), engine.isReady(weightsURL: url) else {
            return .unavailable(reason: "engine not ready")
        }
        // Pin check when weights are a real directory
        if store.requiresInstalledManifestVerification {
            do {
                try L0ModelFetch.verifyInstalled(modelDir: url, manifest: manifest)
            } catch {
                if let fileStore = store as? FileL0WeightStore {
                    do {
                        let quarantined = try L0ModelFetch.quarantineInstalled(
                            modelDir: url,
                            container: fileStore.container
                        )
                        return .unavailable(
                            reason: "model quarantined at \(quarantined.path): \(error.localizedDescription)"
                        )
                    } catch let quarantineError {
                        return .unavailable(
                            reason: "model verification failed; quarantine failed: \(quarantineError.localizedDescription)"
                        )
                    }
                }
                return .unavailable(reason: "model verification failed: \(error.localizedDescription)")
            }
        }
        return .available
    }

    public func complete(prompt: String) async throws -> ModelCompletion {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelRungError.emptyPrompt }
        let avail = await availability()
        guard avail.isAvailable else {
            if case .unavailable(let r) = avail {
                throw ModelRungError.unavailable(.l0Packaged, r)
            }
            throw ModelRungError.unavailable(.l0Packaged, "unavailable")
        }
        guard let url = store.weightsURL(for: manifest.modelID) else {
            throw ModelRungError.unavailable(.l0Packaged, "no weights URL")
        }
        let text = try await engine.complete(prompt: trimmed, weightsURL: url)
        return ModelCompletion(text: text, rung: .l0Packaged, egressSummary: "")
    }

    public func grantConsent() throws {
        try store.setConsent(L0Consent(granted: true, modelID: manifest.modelID, grantedAt: Date()))
    }
}

public enum SummonCorePaths {
    public static func modelsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let fm = FileManager.default
        if let override = environment["SUMMON_CONTAINER_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
        }
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ModelRungError.generationFailed("Application Support unavailable")
        }
        return base.appendingPathComponent("Summon/Models", isDirectory: true)
    }
}
