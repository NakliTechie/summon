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

    func testRejectsUnknownAndExtraneousFields() throws {
        let unknown = Data(#"{"v":1,"action":"settings.delete","key":"x","surprise":true}"#.utf8)
        XCTAssertThrowsError(try gate.decodeAction(from: unknown))

        let extraneous = Data(#"{"v":1,"action":"settings.delete","key":"x","body":"hidden"}"#.utf8)
        XCTAssertThrowsError(try gate.decodeAction(from: extraneous))
    }

    func testRejectsOversizedDocumentAndString() throws {
        let oversized = Data(repeating: UInt8(ascii: "x"), count: SchemaGate.maximumDocumentBytes + 1)
        XCTAssertThrowsError(try gate.decodeAction(from: oversized))

        let object: [String: Any] = [
            "v": 1,
            "action": "snippet.upsert",
            "id": "s",
            "key": "name",
            "body": String(repeating: "x", count: SchemaGate.maximumStringBytes + 1),
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try gate.decodeAction(from: data))
    }

    func testRejectsExcessiveNesting() throws {
        var value: Any = true
        for _ in 0...(SchemaGate.maximumNestingDepth + 1) { value = [value] }
        let data = try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "action": "settings.set",
            "key": "nested",
            "value": value,
        ])
        XCTAssertThrowsError(try gate.decodeAction(from: data))
    }

    func testQuicklinkAllowsHTTPSAndRejectsUnsupportedSchemes() throws {
        let valid = Data(
            #"{"v":1,"action":"quicklink.upsert","id":"q","key":"Docs","url":"https://example.com/x"}"#.utf8
        )
        XCTAssertNoThrow(try gate.decodeAction(from: valid))

        for url in ["javascript:alert(1)", "file:///tmp/secret", "ftp://example.com/x", "https:///missing"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "v": 1,
                "action": "quicklink.upsert",
                "id": "q",
                "key": "Docs",
                "url": url,
            ])
            XCTAssertThrowsError(try gate.decodeAction(from: data), "accepted \(url)")
        }
    }

    func testRejectsOverlongURL() throws {
        let url = "https://example.com/" + String(repeating: "x", count: SchemaGate.maximumURLBytes)
        let data = try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "action": "quicklink.upsert",
            "id": "q",
            "key": "Docs",
            "url": url,
        ])
        XCTAssertThrowsError(try gate.decodeAction(from: data))
    }

    func testModuleRunExternalRoundTrip() throws {
        let action = CoreAction.moduleRun(
            name: "window.arrange",
            targetID: "window:leftHalf",
            path: nil,
            payload: ["layout": .string("leftHalf"), "gap": .number(8)]
        )
        let data = try gate.encodeDocument(action)
        XCTAssertEqual(try gate.decodeAction(from: data), action)
    }

    func testModuleRunRejectsMissingAndOverlongFields() throws {
        XCTAssertThrowsError(
            try gate.decodeAction(
                from: Data(#"{"v":1,"action":"module.run","targetID":"x"}"#.utf8)
            )
        )
        let data = try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "action": "module.run",
            "module": "quicklink.open",
            "targetID": "q",
            "payload": ["url": "https://example.com/" + String(repeating: "x", count: 4_096)],
        ])
        XCTAssertThrowsError(try gate.decodeAction(from: data))
    }

    func testDeferredExtensionAuthorityActionsAreNotExternalWireable() throws {
        XCTAssertThrowsError(
            try gate.encodeDocument(.extensionInstall(sourcePath: "/tmp/example-extension"))
        )
        XCTAssertThrowsError(
            try gate.encodeDocument(
                .extensionGrant(extensionID: "example", entitlement: "network", granted: true)
            )
        )

        let documents = [
            Data(
                #"{"v":1,"action":"extension.install","sourcePath":"/tmp/example-extension"}"#.utf8
            ),
            Data(
                #"{"v":1,"action":"extension.grant","extensionID":"example","entitlement":"network","granted":true}"#.utf8
            ),
        ]
        for document in documents {
            XCTAssertThrowsError(try gate.decodeAction(from: document))
        }
    }
}
