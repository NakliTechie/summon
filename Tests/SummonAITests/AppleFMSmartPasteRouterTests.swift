import XCTest
@testable import SummonAI
@testable import SummonCore

/// `AppleFMSmartPasteRouter` with the model replaced by a fixed answer: the
/// grounding guard, the fallback for empty fields, and the fallback when the
/// model cannot answer. No Apple Intelligence needed.
final class AppleFMSmartPasteRouterTests: XCTestCase {
    private let source = """
        Ananya Iyer, senior iOS engineer at Lumora Health. ananya.iyer@lumora.example, +91 55555 01234.
        """
    private let fields = [
        SmartPasteFieldDescriptor(id: "name", label: "Speaker name"),
        SmartPasteFieldDescriptor(id: "talk", label: "Talk title"),
        SmartPasteFieldDescriptor(id: "email", label: "Email"),
        SmartPasteFieldDescriptor(id: "phone", label: "Phone"),
        SmartPasteFieldDescriptor(id: "pw", label: "Password", role: "AXSecureTextField", isSecure: true),
    ]

    private func route(
        _ answer: [String: String],
        error: Error? = nil,
        delay: Double = 0,
        timeout: Double = 15,
        seen: SeenFields? = nil
    ) async throws -> [String: String] {
        let router = AppleFMSmartPasteRouter(
            generate: { _, fields in
                await seen?.set(fields.map(\.id))
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                if let error { throw error }
                return answer
            },
            fallback: DeterministicSmartPasteRouter(),
            timeoutSeconds: timeout
        )
        let entities = EntityExtractor().extract(from: source)
        let fills = try await router.route(sourceText: source, entities: entities, into: fields)
        return Dictionary(fills.map { ($0.fieldID, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    func testDropsAMadeUpValueAndKeepsACopiedOne() async throws {
        let filled = try await route(["name": "Ananya Iyer", "talk": "Building Patient Apps at Scale"])
        XCTAssertEqual(filled["name"], "Ananya Iyer")
        XCTAssertNil(filled["talk"], "a title the text never states is dropped, not filled")
    }

    func testTheFloorFillsWhatTheModelLeftEmptyWithoutRepeatingAValue() async throws {
        // The model filled the email and left the phone empty; the floor takes the phone.
        let filled = try await route(["email": "ananya.iyer@lumora.example", "phone": ""])
        XCTAssertEqual(filled["email"], "ananya.iyer@lumora.example")
        XCTAssertNotNil(filled["phone"], "the deterministic floor fills the phone the model skipped")
        XCTAssertEqual(Set(filled.values).count, filled.count, "no value lands in two fields")
    }

    func testNeverShowsTheModelASecureField() async throws {
        let seen = SeenFields()
        _ = try await route([:], seen: seen)
        let ids = await seen.ids
        XCTAssertFalse(ids.contains("pw"))
        XCTAssertEqual(ids.count, 4)
    }

    func testFallsBackToTheFloorWhenTheModelFails() async throws {
        let filled = try await route([:], error: ModelRungError.unavailable(.appleFM, "off"))
        XCTAssertNotNil(filled["email"], "the floor still fills the email by its label")
        XCTAssertNil(filled["pw"])
    }

    func testFallsBackToTheFloorWhenTheModelIsTooSlow() async throws {
        let started = Date()
        // "Talk title" has no floor cue, so only the model could fill it.
        let filled = try await route(["talk": "Lumora Health"], delay: 5, timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the timeout stops waiting on the model")
        XCTAssertNil(filled["talk"], "a late answer is not used")
        XCTAssertNotNil(filled["email"])
    }
}

private actor SeenFields {
    var ids: [String] = []
    func set(_ ids: [String]) { self.ids = ids }
}
