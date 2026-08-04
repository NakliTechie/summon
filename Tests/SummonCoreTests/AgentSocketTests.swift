import XCTest
@testable import SummonCore

final class AgentSocketTests: XCTestCase {
    func testVersionOp() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let server = AgentSocketServer(core: core)
        let data = try server.handleRequest(Data(#"{"op":"version"}"#.utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        XCTAssertEqual(obj?["version"] as? String, SummonVersion.string)
    }

    func testSearchOp() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let server = AgentSocketServer(core: core)
        let data = try server.handleRequest(Data(#"{"op":"search","query":"2+2"}"#.utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        let results = obj?["results"] as? [[String: Any]]
        XCTAssertEqual(results?.first?["kind"] as? String, "calculation")
    }

    func testDispatchOpJournalsAgent() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let server = AgentSocketServer(core: core)
        // Non-restricted settings key (agent.* is propose-only)
        let req = """
        {"op":"dispatch","action":{"v":1,"action":"settings.set","key":"cli.test.flag","value":true}}
        """
        let data = try server.handleRequest(Data(req.utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        XCTAssertEqual(try core.settings.get("cli.test.flag"), .bool(true))
        let entries = try core.journal.allEntries()
        XCTAssertEqual(entries.last?.actor, .agent)
    }

    func testDispatchRestrictedSettingStages() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let server = AgentSocketServer(core: core)
        let req = """
        {"op":"dispatch","action":{"v":1,"action":"settings.set","key":"agent.socket.enabled","value":true}}
        """
        let data = try server.handleRequest(Data(req.utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // staged, not applied
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertNil(try core.settings.get("agent.socket.enabled"))
        let staged = try core.staged.list(state: "staged")
        XCTAssertFalse(staged.isEmpty)
    }

    func testUnknownOpFails() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let server = AgentSocketServer(core: core)
        XCTAssertThrowsError(try server.handleRequest(Data(#"{"op":"teleport"}"#.utf8)))
    }

    func testDefaultEnabledSettingKey() {
        XCTAssertEqual(AgentSocketServer.enabledSettingKey, "agent.socket.enabled")
    }
}
