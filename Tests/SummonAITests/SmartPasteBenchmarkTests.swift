import XCTest
@testable import SummonAI
@testable import SummonCore

/// A routing benchmark: fixed entity sets + field descriptors + ground-truth
/// placements, scored top-1 for the deterministic floor and for live verdict-fm.
/// Half the fields are labelled with the obvious token (both routers should get
/// them); half are labelled ambiguously (only a model should). This measures
/// verdict's lift over the floor and keeps a repeatable number for the review.
///
/// Gated: `SUMMON_RUN_VERDICT_LIVE=1 swift test --filter SmartPasteBenchmarkTests`
/// with verdictd running. Skipped otherwise so `make verify` never needs it.
final class SmartPasteBenchmarkTests: XCTestCase {
    private struct Case {
        let name: String
        let entities: [SmartPasteEntity]
        let fields: [SmartPasteFieldDescriptor]
        let expected: [String: String] // entityID → fieldID
    }

    private func entity(_ id: String, _ kind: SmartPasteEntityKind, _ value: String) -> SmartPasteEntity {
        SmartPasteEntity(id: id, kind: kind, value: value, raw: value)
    }
    private func field(_ id: String, _ label: String) -> SmartPasteFieldDescriptor {
        SmartPasteFieldDescriptor(id: id, label: label)
    }

    private func fixture() -> [Case] {
        [
            Case(
                name: "clear labels",
                entities: [entity("e-email", .email, "priya@atlas.example"),
                           entity("e-phone", .phone, "+91 98765 43210")],
                fields: [field("f-email", "Email"), field("f-phone", "Phone")],
                expected: ["e-email": "f-email", "e-phone": "f-phone"]
            ),
            Case(
                name: "ambiguous name field",
                entities: [entity("e-name", .name, "Dr. Priya Raman")],
                fields: [field("f-to", "Addressed to"), field("f-subject", "Subject")],
                expected: ["e-name": "f-to"]
            ),
            Case(
                name: "ambiguous org field",
                entities: [entity("e-org", .organization, "Atlas Robotics")],
                fields: [field("f-inst", "Institution"), field("f-role", "Job title")],
                expected: ["e-org": "f-inst"]
            ),
            Case(
                name: "mixed clear + ambiguous",
                entities: [entity("e-email", .email, "sam@vendor.example"),
                           entity("e-org", .organization, "Vendor Co")],
                fields: [field("f-email", "Email address"), field("f-vendor", "Bill from")],
                expected: ["e-email": "f-email", "e-org": "f-vendor"]
            ),
            Case(
                name: "person into contact card",
                entities: [entity("e-name", .name, "Jane Okafor"),
                           entity("e-city", .address, "Bengaluru")],
                fields: [field("f-recipient", "Recipient"), field("f-location", "Location")],
                expected: ["e-name": "f-recipient", "e-city": "f-location"]
            ),
        ]
    }

    private func score(_ router: SmartPasteRouter, _ cases: [Case]) async throws -> (correct: Int, total: Int) {
        var correct = 0
        var total = 0
        for testCase in cases {
            total += testCase.expected.count
            let fills = try await router.route(entities: testCase.entities, into: testCase.fields)
            let placed = Dictionary(uniqueKeysWithValues: fills.map { ($0.entityID, $0.fieldID) })
            for (entityID, expectedField) in testCase.expected where placed[entityID] == expectedField {
                correct += 1
            }
        }
        return (correct, total)
    }

    func testVerdictFMLiftOverDeterministicFloor() async throws {
        guard ProcessInfo.processInfo.environment["SUMMON_RUN_VERDICT_LIVE"] == "1" else {
            throw XCTSkip("set SUMMON_RUN_VERDICT_LIVE=1 with verdictd running to benchmark routing")
        }
        let cases = fixture()
        let deterministic = try await score(DeterministicSmartPasteRouter(), cases)
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let verdict = try await score(
            VerdictSmartPasteRouter(transport: CoreAuthorizedVerdictTransport(core: core), model: "verdict-fm"),
            cases
        )
        print("BENCH deterministic \(deterministic.correct)/\(deterministic.total)")
        print("BENCH verdict-fm    \(verdict.correct)/\(verdict.total)")
        XCTAssertGreaterThanOrEqual(
            verdict.correct, deterministic.correct,
            "verdict-fm should not route worse than the deterministic floor"
        )
    }
}
