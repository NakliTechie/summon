import CryptoKit
import Foundation
import SummonCore

/// Opt-in fetch of a pinned MLX model tree. Every inference artifact is checked
/// against the immutable in-app manifest before the tree becomes available.
public enum L0ModelFetch {
    public static let receiptFileName = "summon-model-receipt.json"
    private static let fetchTimeout: TimeInterval = 30 * 60

    public struct Receipt: Sendable, Hashable, Codable, Equatable {
        public let modelID: String
        public let hfRepo: String
        public let hfRevision: String
        public let artifacts: [L0ModelManifest.Artifact]

        public init(manifest: L0ModelManifest) {
            modelID = manifest.modelID
            hfRepo = manifest.hfRepo
            hfRevision = manifest.hfRevision
            artifacts = manifest.artifacts
        }
    }

    public enum FetchError: Error, LocalizedError, Equatable {
        case notConsented
        case huggingfaceCLIMissing
        case processFailed(String)
        case invalidManifest(String)
        case artifactMissing(String)
        case artifactSizeMismatch(path: String, expected: Int64, actual: Int64)
        case hashMismatch(path: String, expected: String, actual: String)
        case unexpectedWeightFiles([String])
        case receiptMismatch
        case quarantined(reason: String, path: String)
        case rollbackFailed(install: String, rollback: String, priorPath: String)
        case storage(String)

        public var errorDescription: String? {
            switch self {
            case .notConsented:
                return "L0 consent required before fetch (run: ai l0-consent)"
            case .huggingfaceCLIMissing:
                return "Hugging Face CLI not found at a trusted absolute path"
            case .processFailed(let reason):
                return reason
            case .invalidManifest(let reason):
                return "invalid embedded model manifest: \(reason)"
            case .artifactMissing(let path):
                return "model artifact missing: \(path)"
            case .artifactSizeMismatch(let path, let expected, let actual):
                return "model artifact size mismatch for \(path): expected=\(expected) actual=\(actual)"
            case .hashMismatch(let path, let expected, let actual):
                return "model artifact digest mismatch for \(path): expected=\(expected) actual=\(actual)"
            case .unexpectedWeightFiles(let paths):
                return "unmanifested model weight files: \(paths.joined(separator: ", "))"
            case .receiptMismatch:
                return "installed model receipt does not match the embedded immutable manifest"
            case .quarantined(let reason, let path):
                return "model tree quarantined at \(path): \(reason)"
            case .rollbackFailed(let install, let rollback, let priorPath):
                return "model install failed: \(install); prior tree at \(priorPath) "
                    + "could not be restored: \(rollback)"
            case .storage(let reason):
                return "model storage error: \(reason)"
            }
        }
    }

    public static let trustedHFCLIPaths = [
        "/Library/Frameworks/Python.framework/Versions/3.12/bin/hf",
        "/Library/Frameworks/Python.framework/Versions/3.12/bin/huggingface-cli",
        "/opt/homebrew/bin/hf",
        "/opt/homebrew/bin/huggingface-cli",
        "/usr/local/bin/hf",
        "/usr/local/bin/huggingface-cli",
    ]

    public static func detectHFCLI() -> String? {
        trustedHFCLIPaths.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    public static func digestFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func writeReceipt(manifest: L0ModelManifest, modelDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Receipt(manifest: manifest))
        try data.write(to: modelDir.appendingPathComponent(receiptFileName), options: .atomic)
    }

    public static func readReceipt(modelDir: URL) -> Receipt? {
        let url = modelDir.appendingPathComponent(receiptFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    public static func verifyInstalled(modelDir: URL, manifest: L0ModelManifest) throws {
        try validate(manifest: manifest)
        if let receipt = readReceipt(modelDir: modelDir), receipt != Receipt(manifest: manifest) {
            throw FetchError.receiptMismatch
        }

        for artifact in manifest.artifacts {
            let file = try containedArtifactURL(path: artifact.path, modelDir: modelDir)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw FetchError.artifactMissing(artifact.path)
            }
            let size = Int64(values.fileSize ?? -1)
            guard size == artifact.byteCount else {
                throw FetchError.artifactSizeMismatch(
                    path: artifact.path,
                    expected: artifact.byteCount,
                    actual: size
                )
            }
            let actual = try digestFile(at: file)
            guard actual == artifact.sha256 else {
                throw FetchError.hashMismatch(path: artifact.path, expected: artifact.sha256, actual: actual)
            }
        }

        let expectedWeights = Set(
            manifest.artifacts.filter { $0.role == .weight }.map(\.path)
        )
        let actualWeights = try weightFiles(in: modelDir)
        let unexpected = actualWeights.subtracting(expectedWeights).sorted()
        guard unexpected.isEmpty else {
            throw FetchError.unexpectedWeightFiles(unexpected)
        }
    }

    public static func fetch(
        rung: L0PackagedModelRung,
        store: FileL0WeightStore,
        authorization: EgressAuthorization? = nil
    ) throws -> URL {
        let consent = store.consent()
        guard consent.granted, consent.modelID == rung.manifest.modelID else {
            throw FetchError.notConsented
        }
        guard let cli = detectHFCLI() else { throw FetchError.huggingfaceCLIMissing }
        try validate(manifest: rung.manifest)
        let providerURL = URL(string: "https://huggingface.co/\(rung.manifest.hfRepo)")!
        guard authorization?.permits(url: providerURL, purpose: .userModelFetch) == true else {
            throw FetchError.processFailed("model fetch lacks matching journaled egress authorization")
        }

        let staging = store.container.appendingPathComponent(
            ".incoming-\(rung.manifest.modelID)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            let result = try BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: cli),
                arguments: [
                    "download", rung.manifest.hfRepo,
                    "--revision", rung.manifest.hfRevision,
                    "--local-dir", staging.path,
                ],
                timeout: fetchTimeout,
                maximumStandardOutputBytes: 1_024 * 1_024,
                maximumStandardErrorBytes: 1_024 * 1_024
            )
            guard result.terminationStatus == 0 else {
                let stderr = String(data: result.standardError, encoding: .utf8) ?? ""
                throw FetchError.processFailed(
                    "Hugging Face CLI exited \(result.terminationStatus): \(stderr.prefix(600))"
                )
            }
            let destination = store.container.appendingPathComponent(
                rung.manifest.modelID,
                isDirectory: true
            )
            return try installDownloadedTree(
                stagingDir: staging,
                destination: destination,
                container: store.container,
                manifest: rung.manifest
            )
        } catch let error as FetchError {
            if case .quarantined = error { throw error }
            throw try quarantineFailure(error, tree: staging, container: store.container)
        } catch {
            throw try quarantineFailure(error, tree: staging, container: store.container)
        }
    }

    static func installDownloadedTree(
        stagingDir: URL,
        destination: URL,
        container: URL,
        manifest: L0ModelManifest,
        moveItem: (URL, URL) throws -> Void = { source, target in
            try FileManager.default.moveItem(at: source, to: target)
        }
    ) throws -> URL {
        do {
            try verifyInstalled(modelDir: stagingDir, manifest: manifest)
            try writeReceipt(manifest: manifest, modelDir: stagingDir)
        } catch {
            throw try quarantineFailure(error, tree: stagingDir, container: container)
        }

        var priorTree: URL?
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                priorTree = try quarantine(
                    tree: destination,
                    container: container,
                    label: "replaced",
                    moveItem: moveItem
                )
            }
            try moveItem(stagingDir, destination)
            return destination
        } catch let installError {
            if let priorTree,
               !FileManager.default.fileExists(atPath: destination.path) {
                do {
                    try moveItem(priorTree, destination)
                } catch let rollbackError {
                    throw FetchError.rollbackFailed(
                        install: installError.localizedDescription,
                        rollback: rollbackError.localizedDescription,
                        priorPath: priorTree.path
                    )
                }
            }
            throw FetchError.storage(installError.localizedDescription)
        }
    }

    public static func quarantineInstalled(
        modelDir: URL,
        container: URL
    ) throws -> URL {
        try quarantine(tree: modelDir, container: container, label: "invalid")
    }

    private static func quarantineFailure(
        _ error: Error,
        tree: URL,
        container: URL
    ) throws -> FetchError {
        guard FileManager.default.fileExists(atPath: tree.path) else {
            return .storage(error.localizedDescription)
        }
        let quarantined = try quarantine(tree: tree, container: container, label: "rejected")
        return .quarantined(reason: error.localizedDescription, path: quarantined.path)
    }

    private static func quarantine(
        tree: URL,
        container: URL,
        label: String,
        moveItem: (URL, URL) throws -> Void = { source, target in
            try FileManager.default.moveItem(at: source, to: target)
        }
    ) throws -> URL {
        let quarantineRoot = container.appendingPathComponent("Quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
        let safeName = tree.lastPathComponent.replacingOccurrences(of: "/", with: "-")
        let destination = quarantineRoot.appendingPathComponent(
            "\(safeName)-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try moveItem(tree, destination)
            return destination
        } catch {
            throw FetchError.storage("could not quarantine \(tree.path): \(error.localizedDescription)")
        }
    }

    private static func validate(manifest: L0ModelManifest) throws {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard manifest.hfRevision.count == 40,
              manifest.hfRevision.unicodeScalars.allSatisfy(hex.contains) else {
            throw FetchError.invalidManifest("revision must be a full 40-character lowercase commit")
        }
        guard !manifest.artifacts.isEmpty,
              manifest.artifacts.contains(where: { $0.role == .weight }) else {
            throw FetchError.invalidManifest("at least one weight artifact is required")
        }
        let paths = manifest.artifacts.map(\.path)
        guard Set(paths).count == paths.count else {
            throw FetchError.invalidManifest("artifact paths must be unique")
        }
        for artifact in manifest.artifacts {
            guard artifact.byteCount > 0,
                  artifact.sha256.count == 64,
                  artifact.sha256.unicodeScalars.allSatisfy(hex.contains) else {
                throw FetchError.invalidManifest("invalid size or SHA-256 for \(artifact.path)")
            }
            _ = try containedArtifactURL(path: artifact.path, modelDir: URL(fileURLWithPath: "/model"))
        }
    }

    private static func containedArtifactURL(path: String, modelDir: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw FetchError.invalidManifest("artifact path escapes the model directory: \(path)")
        }
        let root = modelDir.standardizedFileURL.path
        let candidate = modelDir.appendingPathComponent(path).standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else {
            throw FetchError.invalidManifest("artifact path escapes the model directory: \(path)")
        }
        return URL(fileURLWithPath: candidate)
    }

    private static func weightFiles(in modelDir: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: modelDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw FetchError.storage("could not enumerate \(modelDir.path)")
        }
        var result: Set<String> = []
        let root = modelDir.standardizedFileURL.path + "/"
        for case let file as URL in enumerator where file.pathExtension == "safetensors" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            result.insert(String(file.standardizedFileURL.path.dropFirst(root.count)))
        }
        return result
    }
}
