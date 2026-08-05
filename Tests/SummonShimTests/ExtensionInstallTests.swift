import XCTest
@testable import SummonShim
@testable import SummonCore

final class ExtensionInstallTests: XCTestCase {
    func testInstallAndGrantAndStorage() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pkg = tmp.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let manifest = """
        {"v":1,"name":"demo-list","title":"Demo List","commands":[{"name":"show","title":"Show","mode":"view"}],"entitlements":["network"]}
        """
        try Data(manifest.utf8).write(to: pkg.appendingPathComponent("package.json"))

        let regRoot = tmp.appendingPathComponent("reg", isDirectory: true)
        let reg = ExtensionRegistry(root: regRoot)
        let rec = try reg.install(fromDirectory: pkg)
        XCTAssertEqual(rec.extensionID, "demo-list")
        XCTAssertEqual(reg.list().count, 1)

        XCTAssertFalse(reg.isGranted(extensionID: "demo-list", entitlement: "network"))
        try reg.setGrant(extensionID: "demo-list", entitlement: "network", granted: true)
        XCTAssertTrue(reg.isGranted(extensionID: "demo-list", entitlement: "network"))

        reg.storageSet(extensionID: "demo-list", key: "k", value: "v")
        XCTAssertEqual(reg.storageGet(extensionID: "demo-list", key: "k"), "v")

        // durable reload
        let reg2 = ExtensionRegistry(root: regRoot)
        XCTAssertEqual(reg2.list().count, 1)
        XCTAssertTrue(reg2.isGranted(extensionID: "demo-list", entitlement: "network"))
        XCTAssertEqual(reg2.storageGet(extensionID: "demo-list", key: "k"), "v")
    }

    func testRaycastBackupImport() throws {
        let core = try SummonCore.inMemory()
        let json = """
        {"snippets":[{"name":"sig","text":"Best regards","keyword":"sig"}],"quicklinks":[{"name":"GH","link":"https://github.com","keyword":"gh"}]}
        """
        let (sc, qc) = try RaycastBackupImport.importBackup(data: Data(json.utf8), core: core)
        XCTAssertEqual(sc, 1)
        XCTAssertEqual(qc, 1)
        XCTAssertEqual(try core.snippets.all().count, 1)
        XCTAssertEqual(try core.quicklinks.all().count, 1)
        // Re-import upserts (stable ids)
        _ = try RaycastBackupImport.importBackup(data: Data(json.utf8), core: core)
        XCTAssertEqual(try core.snippets.all().count, 1)
        XCTAssertEqual(try core.quicklinks.all().count, 1)
    }

    func testPathTraversalNameRejected() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-ext-trav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pkg = tmp.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let manifest = """
        {"v":1,"name":"../../escape","title":"Bad","commands":[{"name":"x","title":"X"}]}
        """
        try Data(manifest.utf8).write(to: pkg.appendingPathComponent("package.json"))
        let reg = ExtensionRegistry(root: tmp.appendingPathComponent("reg", isDirectory: true))
        XCTAssertThrowsError(try reg.install(fromDirectory: pkg))
    }

    func testManifestGateRejectsUnknownAndBoundViolations() throws {
        let unknownRoot = Data(
            #"{"v":1,"name":"x","title":"X","commands":[{"name":"run","title":"Run"}],"extra":true}"#.utf8
        )
        XCTAssertThrowsError(try ManifestGate.decode(from: unknownRoot))

        let unknownCommand = Data(
            #"{"v":1,"name":"x","title":"X","commands":[{"name":"run","title":"Run","extra":true}]}"#.utf8
        )
        XCTAssertThrowsError(try ManifestGate.decode(from: unknownCommand))

        var nested: Any = "entry.js"
        for _ in 0...(SchemaGate.maximumNestingDepth + 1) { nested = [nested] }
        let nestedData = try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "name": "x",
            "title": "X",
            "commands": [["name": "run", "title": "Run", "entry": nested]],
        ])
        XCTAssertThrowsError(try ManifestGate.decode(from: nestedData))

        var oversized = Data(
            #"{"v":1,"name":"x","title":"X","commands":[{"name":"run","title":"Run"}]}"#.utf8
        )
        oversized.append(Data(repeating: UInt8(ascii: " "), count: SchemaGate.maximumDocumentBytes))
        XCTAssertThrowsError(try ManifestGate.decode(from: oversized))

        let invalidCommand = Data(
            #"{"v":1,"name":"x","title":"X","commands":[{"name":"../run","title":"Run"}]}"#.utf8
        )
        XCTAssertThrowsError(try ManifestGate.decode(from: invalidCommand))
    }

    func testExtensionAuthorityActionsAreJournaled() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-ext-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pkg = tmp.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let manifest = """
        {"v":1,"name":"journaled","title":"Journaled","commands":[{"name":"run","title":"Run","mode":"view"}],"entitlements":["network"]}
        """
        try Data(manifest.utf8).write(to: pkg.appendingPathComponent("package.json"))

        let registry = ExtensionRegistry(
            root: tmp.appendingPathComponent("registry", isDirectory: true)
        )
        let executor = ProcessModuleExecutor(
            extensionInstaller: { sourcePath in
                _ = try registry.install(
                    fromDirectory: URL(fileURLWithPath: sourcePath, isDirectory: true)
                )
            },
            extensionGrantSetter: { extensionID, entitlement, granted in
                try registry.setGrant(
                    extensionID: extensionID,
                    entitlement: entitlement,
                    granted: granted
                )
            }
        )
        let core = try SummonCore.inMemory(executor: executor)

        let installResult = try core.dispatch(
            action: .extensionInstall(sourcePath: pkg.path),
            actor: .user
        )
        XCTAssertTrue(installResult.isApplied, "\(installResult.outcome)")
        let grantResult = try core.dispatch(
                action: .extensionGrant(
                    extensionID: "journaled",
                    entitlement: "network",
                    granted: true
                ),
                actor: .user
        )
        XCTAssertTrue(grantResult.isApplied, "\(grantResult.outcome)")
        XCTAssertTrue(registry.isGranted(extensionID: "journaled", entitlement: "network"))
        let revokeResult = try core.dispatch(
                action: .extensionGrant(
                    extensionID: "journaled",
                    entitlement: "network",
                    granted: false
                ),
                actor: .user
        )
        XCTAssertTrue(revokeResult.isApplied, "\(revokeResult.outcome)")
        XCTAssertFalse(registry.isGranted(extensionID: "journaled", entitlement: "network"))

        let failed = try core.dispatch(
            action: .extensionGrant(
                extensionID: "missing",
                entitlement: "network",
                granted: true
            ),
            actor: .user
        )
        XCTAssertFalse(failed.isApplied)
        let missingPackage = try core.dispatch(
            action: .extensionInstall(
                sourcePath: tmp.appendingPathComponent("missing", isDirectory: true).path
            ),
            actor: .user
        )
        XCTAssertFalse(missingPackage.isApplied)
        let entries = try core.journal.allEntries()
        XCTAssertEqual(entries.map(\.actor), [.user, .user, .user, .user, .user])
        XCTAssertEqual(
            entries.map(\.action.name),
            [
                "extension.install", "extension.grant", "extension.grant",
                "extension.grant", "extension.install",
            ]
        )
        XCTAssertEqual(entries.filter { $0.outcome == "applied" }.count, 3)
        XCTAssertTrue(entries.last?.outcome.hasPrefix("rejected:") == true)
    }

    func testFetchRequiresUserGrant() throws {
        let manifest = ExtensionManifest(
            name: "net-ext",
            title: "Net",
            commands: [.init(name: "run", title: "Run")],
            entitlements: ["network"]
        )
        let denied = try ShimRuntime(manifest: manifest, grantedEntitlements: [])
        XCTAssertTrue(denied.effectiveEntitlements.isEmpty)
        let granted = try ShimRuntime(manifest: manifest, grantedEntitlements: ["network"])
        XCTAssertTrue(granted.effectiveEntitlements.contains("network"))
        // fetch alias normalizes to network when granted as fetch
        let viaFetch = try ShimRuntime(manifest: manifest, grantedEntitlements: ["fetch"])
        XCTAssertTrue(viaFetch.effectiveEntitlements.contains("network"))
    }

    func testHostGlobalsRemovedAfterBootstrap() throws {
        let manifest = ExtensionManifest(
            name: "plain-ext",
            title: "Plain",
            commands: [.init(name: "run", title: "Run")]
        )
        let runtime = try ShimRuntime(manifest: manifest)
        // Private evaluate — use run of empty component that checks typeof
        let entry = """
        module.exports = function() {
          if (typeof __hostFetch !== 'undefined') throw new Error('__hostFetch leaked');
          if (typeof __hostStorageGet !== 'undefined') throw new Error('__hostStorageGet leaked');
          return { type: 'List', props: {}, children: [] };
        };
        """
        _ = try runtime.run(entrySource: entry)
    }
}
