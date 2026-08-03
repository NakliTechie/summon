import XCTest
import SummonCore
@testable import SummonShim

/// C0 gate: 3 synthetic store-style fixtures render host trees; sandbox escape fails loud.
final class FixtureHarnessTests: XCTestCase {
    let harness = FixtureHarness()

    func testListFixtureRendersItems() throws {
        let result = try runFixture("list-ext")
        XCTAssertEqual(result.tree.type, "List")
        let items = result.tree.all(ofType: "List.Item")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].props["title"], .string("Invoice Q3"))
        XCTAssertEqual(items[1].props["title"], .string("Receipt 1042"))
        XCTAssertEqual(result.tree.props["searchBarPlaceholder"], .string("Search items"))
    }

    func testFormFixtureRendersFields() throws {
        let result = try runFixture("form-ext")
        XCTAssertEqual(result.tree.type, "Form")
        let fields = result.tree.all(ofType: "Form.TextField")
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].props["id"], .string("title"))
        XCTAssertEqual(result.tree.all(ofType: "Form.TextArea").count, 1)
        XCTAssertEqual(result.tree.all(ofType: "Form.Checkbox").count, 1)
        // Raycast nests actions under props.actions (not as a child).
        guard case .object(let actions)? = result.tree.props["actions"] else {
            return XCTFail("expected props.actions object")
        }
        XCTAssertEqual(actions["type"], .string("ActionPanel"))
    }

    func testFetchStorageFixture() throws {
        let core = try SummonCore.inMemory()
        let result = try runFixture(
            "fetch-storage-ext",
            core: core,
            fetchHandler: { url, method, _, _ in
                XCTAssertEqual(url.absoluteString, "https://example.test/v1/status")
                XCTAssertEqual(method, "GET")
                let body = #"{"title":"remote-ok"}"#
                return ShimRuntime.FetchResponse(
                    ok: true,
                    status: 200,
                    statusText: "OK",
                    text: body,
                    jsonText: body
                )
            }
        )
        XCTAssertEqual(result.tree.type, "List")
        let item = try XCTUnwrap(result.tree.first(ofType: "List.Item"))
        XCTAssertEqual(item.props["title"], .string("remote-ok"))
        XCTAssertEqual(result.storage["visited"], "1")
        XCTAssertEqual(result.storage["count"], "1")
        XCTAssertEqual(result.storage["remoteTitle"], "remote-ok")

        // Bus door: actor=ext:<id>
        XCTAssertEqual(result.busResults.count, 1)
        XCTAssertTrue(result.busResults[0].isApplied)
        let entries = try core.journal.allEntries()
        XCTAssertEqual(entries.last?.actor, .ext(id: "fixture.fetch-storage"))
    }

    func testSandboxEscapeFailsLoud() throws {
        XCTAssertThrowsError(try runFixture("sandbox-escape")) { error in
            let message: String
            if let runtime = error as? ShimRuntime.RuntimeError {
                switch runtime {
                case .javascript(let s), .renderFailed(let s):
                    message = s
                default:
                    message = String(describing: runtime)
                }
            } else {
                message = String(describing: error)
            }
            XCTAssertTrue(
                message.contains("not allowed") || message.contains("require"),
                "expected sandbox denial, got: \(message)"
            )
        }
    }

    func testFetchWithoutEntitlementDenied() throws {
        // list-ext has no network entitlement — inject a command that fetches.
        let manifest = """
        {"v":1,"name":"fixture.no-net","title":"No Net","commands":[{"name":"index","title":"X","mode":"view"}],"entitlements":[]}
        """.data(using: .utf8)!
        let entry = """
        var api = require("@raycast/api");
        var List = api.List;
        var React = require("react");
        var res = fetch("https://example.test/");
        module.exports = function() {
          return React.createElement(List, null,
            React.createElement(List.Item, { title: res.ok ? "ok" : "denied-" + res.statusText })
          );
        };
        """
        let result = try harness.run(manifestJSON: manifest, entrySource: entry)
        let item = try XCTUnwrap(result.tree.first(ofType: "List.Item"))
        // host returns ok:false with entitlement message in statusText
        if case .string(let title) = item.props["title"] {
            XCTAssertTrue(title.contains("denied") || title.contains("entitlement") || title.hasPrefix("denied"),
                          "title=\(title)")
        } else {
            XCTFail("expected string title")
        }
    }

    func testManifestGateRejectsEmptyCommands() {
        let bad = #"{"v":1,"name":"x","title":"X","commands":[]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try ManifestGate.decode(from: bad))
    }

    // MARK: - Helpers

    private func runFixture(
        _ name: String,
        core: SummonCore? = nil,
        fetchHandler: ((URL, String, [String: String], String?) throws -> ShimRuntime.FetchResponse)? = nil
    ) throws -> FixtureHarness.RunResult {
        let (manifest, entry) = try loadFixture(name)
        return try harness.run(
            manifestJSON: manifest,
            entrySource: entry,
            core: core,
            fetchHandler: fetchHandler
        )
    }

    private func loadFixture(_ name: String) throws -> (Data, String) {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        let m = try Data(contentsOf: base.appendingPathComponent("package.json"))
        let e = try String(contentsOf: base.appendingPathComponent("command.js"), encoding: .utf8)
        return (m, e)
    }
}
