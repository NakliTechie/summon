import XCTest
@testable import SummonAI
@testable import SummonCore

private struct StubTransport: VerdictTransport {
    var reply: String
    func systemOne(body: Data) async throws -> Data { Data(reply.utf8) }
}

final class SmartPasteVerdictHardenTests: XCTestCase {
    // B5 — an undecodable verdict response falls back to the deterministic floor, never throws.
    func testUndecodableResponseFallsBackToFloor() async throws {
        let router = VerdictSmartPasteRouter(transport: StubTransport(reply: "<<not json>>"))
        let fills = try await router.route(
            entities: [SmartPasteEntity(id: "e", kind: .email, value: "a@b.com", raw: "a@b.com")],
            into: [SmartPasteFieldDescriptor(id: "field-0", label: "Email")]
        )
        XCTAssertEqual(fills.first?.fieldID, "field-0")
        XCTAssertEqual(fills.first?.confidenceKind, .heuristic, "the floor answered, not verdict")
    }

    // B7 — a verdict choice naming a field outside the option set is ignored, not fabricated.
    func testChoiceOutsideTheFieldSetIsIgnored() async throws {
        let reply = #"{"answers":{"entity_0":{"choice":"ghost-field","confidence":0.9}},"failures":{}}"#
        let router = VerdictSmartPasteRouter(transport: StubTransport(reply: reply))
        let fills = try await router.route(
            entities: [SmartPasteEntity(id: "e", kind: .name, value: "Jane", raw: "Jane")],
            into: [SmartPasteFieldDescriptor(id: "field-0", label: "Recipient")]
        )
        XCTAssertTrue(fills.isEmpty, "a choice not in the offered set must place nothing")
    }

    // C2 — two residue entities both routed to one field yield a single fill (no double-assign).
    func testTwoEntitiesOneFieldYieldsOneFill() async throws {
        let reply = #"""
        {"answers":{"entity_0":{"choice":"field-0","confidence":0.8},"entity_1":{"choice":"field-0","confidence":0.8}},"failures":{}}
        """#
        let router = VerdictSmartPasteRouter(transport: StubTransport(reply: reply))
        let fills = try await router.route(
            entities: [
                SmartPasteEntity(id: "e0", kind: .name, value: "Jane", raw: "Jane"),
                SmartPasteEntity(id: "e1", kind: .name, value: "Sam", raw: "Sam"),
            ],
            into: [SmartPasteFieldDescriptor(id: "field-0", label: "Recipient")]
        )
        XCTAssertEqual(fills.count, 1, "one field takes at most one entity")
    }
}
