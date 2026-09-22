import XCTest
@testable import SummonAI
@testable import SummonCore

private struct FakeTransport: VerdictTransport {
    var reply: String?
    var error: Error?
    func systemOne(body: Data) async throws -> Data {
        if let error { throw error }
        return Data((reply ?? "{\"answers\":{},\"failures\":{}}").utf8)
    }
}

private enum FakeError: Error { case down }

final class VerdictSmartPasteRouterTests: XCTestCase {
    func testVerdictPlacesAResidueEntityTheFloorCannot() async throws {
        // A name entity + a field the deterministic lexicon does not match.
        let entities = [SmartPasteEntity(id: "e0", kind: .name, value: "Jane Doe", raw: "Jane Doe")]
        let fields = [SmartPasteFieldDescriptor(id: "field-0", label: "Recipient")]
        let reply = """
        {"answers":{"entity_0":{"choice":"field-0","confidence":0.82,"confidence_kind":"agreement"}},"failures":{}}
        """
        let router = VerdictSmartPasteRouter(transport: FakeTransport(reply: reply))
        let fills = try await router.route(entities: entities, into: fields)
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills.first?.fieldID, "field-0")
        XCTAssertEqual(fills.first?.confidenceKind, .agreement)
        XCTAssertEqual(fills.first?.confidence ?? 0, 0.82, accuracy: 0.001)
    }

    func testNoneAnswerYieldsNoFill() async throws {
        let entities = [SmartPasteEntity(id: "e0", kind: .name, value: "Jane", raw: "Jane")]
        let fields = [SmartPasteFieldDescriptor(id: "field-0", label: "Recipient")]
        let reply = """
        {"answers":{"entity_0":{"choice":"__none__","confidence":0.9}},"failures":{}}
        """
        let router = VerdictSmartPasteRouter(transport: FakeTransport(reply: reply))
        let fills = try await router.route(entities: entities, into: fields)
        XCTAssertTrue(fills.isEmpty, "a __none__ choice must not fabricate a fill")
    }

    func testFallsBackToDeterministicWhenVerdictIsDown() async throws {
        // The floor can place this on its own; verdict being down must not lose it.
        let entities = [SmartPasteEntity(id: "e0", kind: .email, value: "a@b.com", raw: "a@b.com")]
        let fields = [SmartPasteFieldDescriptor(id: "field-0", label: "Email")]
        let router = VerdictSmartPasteRouter(transport: FakeTransport(error: FakeError.down))
        let fills = try await router.route(entities: entities, into: fields)
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills.first?.fieldID, "field-0")
        XCTAssertEqual(fills.first?.confidenceKind, .heuristic, "fallback fills are heuristic")
    }

    func testFloorPlacesWhatItCanThenVerdictHandlesResidue() async throws {
        let entities = [
            SmartPasteEntity(id: "e-mail", kind: .email, value: "a@b.com", raw: "a@b.com"),
            SmartPasteEntity(id: "e-name", kind: .name, value: "Jane Doe", raw: "Jane Doe"),
        ]
        let fields = [
            SmartPasteFieldDescriptor(id: "field-email", label: "Email"),
            SmartPasteFieldDescriptor(id: "field-to", label: "Addressed to"),
        ]
        // verdict is asked only about the residue (the name → "Addressed to").
        let reply = """
        {"answers":{"entity_0":{"choice":"field-to","confidence":0.77,"confidence_kind":"agreement"}},"failures":{}}
        """
        let router = VerdictSmartPasteRouter(transport: FakeTransport(reply: reply))
        let fills = try await router.route(entities: entities, into: fields)
        let byField = Dictionary(uniqueKeysWithValues: fills.map { ($0.fieldID, $0) })
        XCTAssertEqual(byField["field-email"]?.entityID, "e-mail")
        XCTAssertEqual(byField["field-email"]?.confidenceKind, .heuristic)
        XCTAssertEqual(byField["field-to"]?.entityID, "e-name")
        XCTAssertEqual(byField["field-to"]?.confidenceKind, .agreement)
    }

    func testReportedFailuresYieldNoVerdictFills() async throws {
        let entities = [SmartPasteEntity(id: "e0", kind: .name, value: "Jane", raw: "Jane")]
        let fields = [SmartPasteFieldDescriptor(id: "field-0", label: "Recipient")]
        let reply = """
        {"answers":{"entity_0":{"choice":"field-0"}},"failures":{"entity_0":"x"}}
        """
        let router = VerdictSmartPasteRouter(transport: FakeTransport(reply: reply))
        let fills = try await router.route(entities: entities, into: fields)
        XCTAssertTrue(fills.isEmpty, "a response with failures is not trusted")
    }
}
