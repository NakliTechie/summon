import Foundation

/// L0 packaged on-device model.
///
/// **D7 (Chirag 2026-08-04): MLX** via `mlx_lm.generate` process bridge
/// (`MLXProcessL0Engine`). Weights = HF-style directory under Models/, never in cask.
/// Fallback fleet: L1 unavailable (8GB / no Apple Intelligence) → L0 after consent.
public struct L0ModelManifest: Sendable, Hashable, Codable, Equatable {
    public let modelID: String
    public let displayName: String
    public let quant: String
    public let minRAMGB: Int
    public let approxDownloadBytes: Int64
    /// Expected SHA-256 of config.json, or `PENDING_PIN_AFTER_FIRST_FETCH` (pin written on first fetch).
    public let sha256: String
    /// Hugging Face repo id for MLX community models (fetch lands with consent).
    public let hfRepo: String
    /// Optional HF revision/commit; nil uses repo default.
    public let hfRevision: String?

    public var hasPendingPin: Bool {
        sha256 == "PENDING_PIN_AFTER_FIRST_FETCH" || sha256.isEmpty
    }

    public init(
        modelID: String,
        displayName: String,
        quant: String,
        minRAMGB: Int,
        approxDownloadBytes: Int64,
        sha256: String,
        hfRepo: String,
        hfRevision: String? = nil
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.quant = quant
        self.minRAMGB = minRAMGB
        self.approxDownloadBytes = approxDownloadBytes
        self.sha256 = sha256
        self.hfRepo = hfRepo
        self.hfRevision = hfRevision
    }

    public static let e2bDefault = L0ModelManifest(
        modelID: "gemma-2-2b-it-4bit",
        displayName: "Gemma 2 2B Instruct (MLX 4-bit)",
        quant: "4bit",
        minRAMGB: 8,
        approxDownloadBytes: 1_500_000_000,
        sha256: "PENDING_PIN_AFTER_FIRST_FETCH",
        hfRepo: "mlx-community/gemma-2-2b-it-4bit",
        hfRevision: nil
    )

    public static let e4bOptional = L0ModelManifest(
        modelID: "gemma-2-9b-it-4bit",
        displayName: "Gemma 2 9B Instruct (MLX 4-bit, ≥16GB)",
        quant: "4bit",
        minRAMGB: 16,
        approxDownloadBytes: 5_000_000_000,
        sha256: "PENDING_PIN_AFTER_FIRST_FETCH",
        hfRepo: "mlx-community/gemma-2-9b-it-4bit",
        hfRevision: nil
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
    func consent() -> L0Consent
    func setConsent(_ consent: L0Consent)
    func weightsPresent(for modelID: String) -> Bool
    func weightsURL(for modelID: String) -> URL?
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

    public func setConsent(_ consent: L0Consent) {
        guard let data = try? JSONEncoder().encode(consent) else { return }
        try? data.write(to: consentURL, options: .atomic)
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

public final class MemoryL0WeightStore: L0WeightStore, @unchecked Sendable {
    private var cons = L0Consent()
    private var weights: Set<String> = []
    private let lock = NSLock()

    public init() {}

    public func consent() -> L0Consent {
        lock.lock(); defer { lock.unlock() }
        return cons
    }

    public func setConsent(_ consent: L0Consent) {
        lock.lock(); defer { lock.unlock() }
        cons = consent
    }

    public func markWeightsPresent(_ modelID: String) {
        lock.lock(); defer { lock.unlock() }
        weights.insert(modelID)
    }

    public func weightsPresent(for modelID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return weights.contains(modelID)
    }

    public func weightsURL(for modelID: String) -> URL? {
        weightsPresent(for: modelID)
            ? URL(fileURLWithPath: "/tmp/summon-l0/\(modelID)")
            : nil
    }
}

public protocol L0InferenceEngine: Sendable {
    func isReady(weightsURL: URL) -> Bool
    func complete(prompt: String, weightsURL: URL) async throws -> String
}

/// Unit-test stand-in (no MLX binary required). **Not for production paths.**
public struct FakeL0InferenceEngine: L0InferenceEngine, Sendable {
    public init() {}

    public func isReady(weightsURL: URL) -> Bool { true }

    public func complete(prompt: String, weightsURL: URL) async throws -> String {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return "L0-staged: \(t.prefix(160))"
    }
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
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return Int(size / 1_073_741_824)
    }

    public static func recommendedL0Manifest() -> L0ModelManifest {
        totalRAMGB() >= 16 ? .e4bOptional : .e2bDefault
    }
}

public struct L0PackagedModelRung: ModelRung, Sendable {
    public let id: ModelRungID = .l0Packaged
    public let displayName = "Packaged on-device (L0 / MLX)"
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

    /// Production default: MLX process bridge only. Never fakes completions.
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
        guard c.granted else {
            let mb = manifest.approxDownloadBytes / 1_000_000
            return .unavailable(
                reason: "consent required (\(mb) MB \(manifest.displayName) via MLX)"
            )
        }
        guard store.weightsPresent(for: manifest.modelID) else {
            return .unavailable(reason: "weights not installed for \(manifest.modelID)")
        }
        guard let url = store.weightsURL(for: manifest.modelID), engine.isReady(weightsURL: url) else {
            return .unavailable(reason: "engine not ready")
        }
        // Pin check when weights are a real directory
        if !(store is MemoryL0WeightStore) {
            do {
                try L0ModelFetch.verifyInstalled(modelDir: url, manifest: manifest)
            } catch {
                return .unavailable(reason: "pin verify failed: \(error.localizedDescription)")
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

    public func grantConsent() {
        store.setConsent(L0Consent(granted: true, modelID: manifest.modelID, grantedAt: Date()))
    }
}

public enum SummonCorePaths {
    public static func modelsDirectory() throws -> URL {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ModelRungError.generationFailed("Application Support unavailable")
        }
        return base.appendingPathComponent("Summon/Models", isDirectory: true)
    }
}
