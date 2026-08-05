import XCTest
@testable import SummonAI

final class L0ProductionTruthTests: XCTestCase {
    func testModelDirectoryHonorsHermeticContainerOverride() throws {
        let path = try SummonCorePaths.modelsDirectory(environment: [
            "SUMMON_CONTAINER_DIR": "/private/tmp/summon-model-container",
        ])
        XCTAssertEqual(path.path, "/private/tmp/summon-model-container/Models")
    }

    func testProductionWithoutBinaryIsUnavailable() async throws {
        let store = MemoryL0WeightStore()
        let l0 = L0PackagedModelRung(store: store, engine: UnavailableL0InferenceEngine())
        try l0.grantConsent()
        store.markWeightsPresent(l0.manifest.modelID)
        let availability = await l0.availability()
        XCTAssertFalse(availability.isAvailable)
        if case .unavailable(let reason) = availability {
            XCTAssertTrue(reason.contains("mlx") || reason.contains("not installed"))
        } else {
            XCTFail("expected unavailable")
        }
    }

    func testProductionDoesNotUseFakeEngineWhenBinaryMissing() {
        let store = MemoryL0WeightStore()
        let l0 = L0PackagedModelRung.production(store: store)
        if MLXProcessL0Engine.detectBinary() == nil {
            XCTAssertTrue(l0.engine is UnavailableL0InferenceEngine)
        } else {
            XCTAssertTrue(l0.engine is MLXProcessL0Engine)
        }
    }

    func testConsentIsBoundToTheExactModelManifest() async throws {
        let store = MemoryL0WeightStore()
        try store.setConsent(L0Consent(
            granted: true,
            modelID: L0ModelManifest.e2bDefault.modelID,
            grantedAt: Date()
        ))
        store.markWeightsPresent(L0ModelManifest.e4bOptional.modelID)
        let rung = L0PackagedModelRung(
            store: store,
            engine: FakeL0InferenceEngine(),
            manifest: .e4bOptional
        )

        let availability = await rung.availability()
        XCTAssertFalse(availability.isAvailable)
        guard case .unavailable(let reason) = availability else {
            return XCTFail("expected unavailable")
        }
        XCTAssertTrue(reason.contains("consent required"))
        XCTAssertTrue(reason.contains("license gemma"))
    }

    func testFetchRejectsConsentForAnotherModelBeforeCreatingStagingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-l0-consent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileL0WeightStore(container: root)
        try store.setConsent(L0Consent(
            granted: true,
            modelID: L0ModelManifest.e2bDefault.modelID,
            grantedAt: Date()
        ))
        let rung = L0PackagedModelRung(
            store: store,
            engine: UnavailableL0InferenceEngine(),
            manifest: .e4bOptional
        )

        XCTAssertThrowsError(try L0ModelFetch.fetch(rung: rung, store: store)) { error in
            XCTAssertEqual(error as? L0ModelFetch.FetchError, .notConsented)
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(contents, ["l0-consent.json"])
    }

    func testShippingManifestsPinFullRevisionsAndEveryWeight() throws {
        for manifest in [L0ModelManifest.e2bDefault, .e4bOptional] {
            XCTAssertEqual(manifest.hfRevision.count, 40)
            XCTAssertFalse(manifest.artifacts.isEmpty)
            XCTAssertTrue(manifest.artifacts.contains(where: { $0.role == .weight }))
            XCTAssertTrue(manifest.artifacts.allSatisfy { $0.sha256.count == 64 })
            XCTAssertEqual(
                manifest.approxDownloadBytes,
                manifest.artifacts.reduce(0) { $0 + $1.byteCount }
            )
        }
        XCTAssertEqual(
            L0ModelManifest.e2bDefault.artifacts.filter { $0.role == .weight }.map(\.path),
            ["model.safetensors"]
        )
        XCTAssertEqual(
            L0ModelManifest.e4bOptional.artifacts.filter { $0.role == .weight }.map(\.path),
            ["model.safetensors"]
        )
    }

    func testValidModelTreeVerifiesAndReceiptRoundTrips() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try L0ModelFetch.verifyInstalled(modelDir: fixture.model, manifest: fixture.manifest)
        try L0ModelFetch.writeReceipt(manifest: fixture.manifest, modelDir: fixture.model)
        XCTAssertEqual(
            L0ModelFetch.readReceipt(modelDir: fixture.model),
            L0ModelFetch.Receipt(manifest: fixture.manifest)
        )
        try L0ModelFetch.verifyInstalled(modelDir: fixture.model, manifest: fixture.manifest)
    }

    func testTamperedWeightTreeIsQuarantinedBeforeInstall() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.root.appendingPathComponent("installed", isDirectory: true)
        try Data("tampered".utf8).write(
            to: fixture.model.appendingPathComponent("model.safetensors"),
            options: .atomic
        )

        XCTAssertThrowsError(
            try L0ModelFetch.installDownloadedTree(
                stagingDir: fixture.model,
                destination: destination,
                container: fixture.root,
                manifest: fixture.manifest
            )
        ) { error in
            guard case L0ModelFetch.FetchError.quarantined = error else {
                return XCTFail("expected quarantine error, received \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.model.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let quarantine = fixture.root.appendingPathComponent("Quarantine", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: quarantine.path).count, 1)
    }

    func testInstallReportsFailedPriorTreeRollback() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.root.appendingPathComponent("installed", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("prior".utf8).write(to: destination.appendingPathComponent("prior.bin"))
        var moveCount = 0

        XCTAssertThrowsError(
            try L0ModelFetch.installDownloadedTree(
                stagingDir: fixture.model,
                destination: destination,
                container: fixture.root,
                manifest: fixture.manifest,
                moveItem: { source, target in
                    moveCount += 1
                    if moveCount == 1 {
                        try FileManager.default.moveItem(at: source, to: target)
                    } else if moveCount == 2 {
                        throw CocoaError(.fileWriteNoPermission)
                    } else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
            )
        ) { error in
            guard case L0ModelFetch.FetchError.rollbackFailed(
                let install,
                let rollback,
                let priorPath
            ) = error else {
                return XCTFail("expected rollback failure, received \(error)")
            }
            XCTAssertFalse(install.isEmpty)
            XCTAssertFalse(rollback.isEmpty)
            XCTAssertTrue(priorPath.contains("Quarantine"))
        }
        XCTAssertEqual(moveCount, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUnmanifestedWeightFileIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("extra".utf8).write(
            to: fixture.model.appendingPathComponent("unexpected.safetensors"),
            options: .atomic
        )
        XCTAssertThrowsError(
            try L0ModelFetch.verifyInstalled(modelDir: fixture.model, manifest: fixture.manifest)
        ) { error in
            guard case L0ModelFetch.FetchError.unexpectedWeightFiles(let paths) = error else {
                return XCTFail("expected unexpected-weight error, received \(error)")
            }
            XCTAssertEqual(paths, ["unexpected.safetensors"])
        }
    }

    private func makeFixture() throws -> (
        root: URL,
        model: URL,
        manifest: L0ModelManifest
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-l0-fixture-\(UUID().uuidString)", isDirectory: true)
        let model = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)

        let config = Data(#"{"model_type":"fixture"}"#.utf8)
        let weights = Data("fixture-weights".utf8)
        try config.write(to: model.appendingPathComponent("config.json"))
        try weights.write(to: model.appendingPathComponent("model.safetensors"))

        let artifacts = [
            L0ModelManifest.Artifact(
                path: "config.json",
                byteCount: Int64(config.count),
                sha256: try L0ModelFetch.digestFile(at: model.appendingPathComponent("config.json")),
                role: .metadata
            ),
            L0ModelManifest.Artifact(
                path: "model.safetensors",
                byteCount: Int64(weights.count),
                sha256: try L0ModelFetch.digestFile(at: model.appendingPathComponent("model.safetensors")),
                role: .weight
            ),
        ]
        let manifest = L0ModelManifest(
            modelID: "fixture",
            displayName: "Fixture",
            quant: "test",
            minRAMGB: 1,
            approxDownloadBytes: Int64(config.count + weights.count),
            hfRepo: "fixture/model",
            hfRevision: String(repeating: "a", count: 40),
            artifacts: artifacts,
            license: "test"
        )
        return (root, model, manifest)
    }
}
