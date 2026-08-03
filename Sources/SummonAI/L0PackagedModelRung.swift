import Foundation

/// L0 packaged on-device model (Gemma E2B via llama.cpp+Metal — engine lands with D7).
///
/// Day-1 seam: consent gate + availability detection + FakeL0 for tests.
/// Real weights: hash-pinned GGUF under Application Support, never in the cask.
/// Used when L1 (Apple Foundation Models) is unavailable — e.g. 8GB / no Apple Intelligence.
public struct L0ModelManifest: Sendable, Hashable, Codable, Equatable {
    public let modelID: String
    public let displayName: String
    public let quant: String
    public let minRAMGB: Int
    public let approxDownloadBytes: Int64
    public let sha256: String
    public let downloadURL: String

    public static let e2bDefault = L0ModelManifest(
        modelID: "gemma-4-e2b",
        displayName: "Gemma 4 E2B (packaged)",
        quant: "Q4_K_M",
        minRAMGB: 8,
        approxDownloadBytes: 1_600_000_000,
        sha256: "PENDING_PIN_AT_C3",
        downloadURL: "https://huggingface.co/naklitechie/summon-models/resolve/main/gemma-4-e2b.Q4_K_M.gguf"
    )

    public static let e4bOptional = L0ModelManifest(
        modelID: "gemma-4-e4b",
        displayName: "Gemma 4 E4B (optional)",
        quant: "Q4_K_M",
        minRAMGB: 16,
        approxDownloadBytes: 3_200_000_000,
        sha256: "PENDING_PIN_AT_C3",
        downloadURL: "https://huggingface.co/naklitechie/summon-models/resolve/main/gemma-4-e4b.Q4_K_M.gguf"
    )
}

/// User consent for L0 weight fetch (ask before big downloads — invariant 11).
public struct L0Consent: Sendable, Hashable, Codable, Equatable {
    public var granted: Bool
    public var modelID: String
    public var grantedAt: Date?

    public init(granted: Bool = false, modelID: String = L0ModelManifest.e2bDefault.modelID, grantedAt: Date? = nil) {
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

/// File-backed consent + weight paths under Application Support/Summon/Models/.
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
        weightsURL(for: modelID).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    public func weightsURL(for modelID: String) -> URL? {
        let url = container.appendingPathComponent("\(modelID).gguf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// In-memory store for tests.
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
        weightsPresent(for: modelID) ? URL(fileURLWithPath: "/tmp/\(modelID).gguf") : nil
    }
}

/// Inference backend for L0. Real llama.cpp Metal engine swaps in at D7; Fake for tests.
public protocol L0InferenceEngine: Sendable {
    func isReady(weightsURL: URL) -> Bool
    func complete(prompt: String, weightsURL: URL) async throws -> String
}

/// Stand-in until llama.cpp is linked (D7 probe). Deterministic for fixtures.
public struct FakeL0InferenceEngine: L0InferenceEngine, Sendable {
    public init() {}

    public func isReady(weightsURL: URL) -> Bool {
        true
    }

    public func complete(prompt: String, weightsURL: URL) async throws -> String {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return "L0-staged: \(t.prefix(160))"
    }
}

/// Physical RAM helper for E2B vs E4B offer (detected, not a picker).
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

/// L0 rung: consent + weights + engine. Unavailable until user consents and weights exist
/// (or Fake engine + memory store for tests).
public struct L0PackagedModelRung: ModelRung, Sendable {
    public let id: ModelRungID = .l0Packaged
    public let displayName = "Packaged on-device (L0)"
    public let store: any L0WeightStore
    public let engine: any L0InferenceEngine
    public let manifest: L0ModelManifest

    public init(
        store: any L0WeightStore,
        engine: any L0InferenceEngine = FakeL0InferenceEngine(),
        manifest: L0ModelManifest = MachineMemory.recommendedL0Manifest()
    ) {
        self.store = store
        self.engine = engine
        self.manifest = manifest
    }

    public func availability() async -> RungAvailability {
        let c = store.consent()
        guard c.granted else {
            return .unavailable(
                reason: "consent required (\(manifest.approxDownloadBytes / 1_000_000) MB \(manifest.displayName))"
            )
        }
        guard store.weightsPresent(for: manifest.modelID) else {
            return .unavailable(reason: "weights not installed for \(manifest.modelID)")
        }
        guard let url = store.weightsURL(for: manifest.modelID), engine.isReady(weightsURL: url) else {
            return .unavailable(reason: "engine not ready")
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

    /// Record consent (does not download yet — fetch is a separate explicit step).
    public func grantConsent() {
        store.setConsent(L0Consent(granted: true, modelID: manifest.modelID, grantedAt: Date()))
    }
}

/// Paths for models (keeps SummonAI free of circular deps on full SummonCore init).
public enum SummonCorePaths {
    public static func modelsDirectory() throws -> URL {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ModelRungError.generationFailed("Application Support unavailable")
        }
        return base.appendingPathComponent("Summon/Models", isDirectory: true)
    }
}
