import XCTest
@testable import SummonCore

final class SchemaGateTests: XCTestCase {
    let gate = SchemaGate()

    func testSettingsSet() throws {
        let json = """
        {"v":1,"action":"settings.set","key":"theme","value":"dark"}
        """.data(using: .utf8)!
        let action = try gate.decodeAction(from: json)
        XCTAssertEqual(action, .settingsSet(key: "theme", value: .string("dark")))
    }

    func testSettingsDelete() throws {
        let json = """
        {"v":1,"action":"settings.delete","key":"theme"}
        """.data(using: .utf8)!
        let action = try gate.decodeAction(from: json)
        XCTAssertEqual(action, .settingsDelete(key: "theme"))
    }

    func testRejectsUnknownAction() {
        let json = """
        {"v":1,"action":"teleport.moon"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try gate.decodeAction(from: json))
    }

    func testRejectsWrongVersion() {
        let json = """
        {"v":99,"action":"settings.set","key":"a","value":"b"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try gate.decodeAction(from: json))
    }

    func testRejectsMissingKey() {
        let json = """
        {"v":1,"action":"settings.set","value":"x"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try gate.decodeAction(from: json))
    }

    func testEnvelopeActorFromDoorNotPayload() throws {
        let json = """
        {"v":1,"action":"settings.set","key":"k","value":true}
        """.data(using: .utf8)!
        let env = try gate.envelope(from: json, actor: .system)
        XCTAssertEqual(env.actor, .system)
        XCTAssertEqual(env.action, .settingsSet(key: "k", value: .bool(true)))
    }

    func testEncodeDecodeRoundTrip() throws {
        let action = CoreAction.settingsSet(key: "agent.enabled", value: .bool(false))
        let data = try gate.encodeDocument(action)
        let decoded = try gate.decodeAction(from: data)
        XCTAssertEqual(decoded, action)
    }
}
