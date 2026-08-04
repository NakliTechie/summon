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
        reg.setGrant(extensionID: "demo-list", entitlement: "network", granted: true)
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
