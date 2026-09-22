import XCTest
@testable import SummonAI
@testable import SummonCore

/// A live pilot against a running verdictd (`~/Code/verdict`). Skipped unless
/// SUMMON_RUN_VERDICT_LIVE=1 so `make verify` never depends on the daemon.
/// Run: `SUMMON_RUN_VERDICT_LIVE=1 swift test --filter VerdictLivePilotTests`.
final class VerdictLivePilotTests: XCTestCase {
    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["SUMMON_RUN_VERDICT_LIVE"] == "1" else {
            throw XCTSkip("set SUMMON_RUN_VERDICT_LIVE=1 with verdictd running to pilot the loopback integration")
        }
    }

    func testRoutesAContactBlockThroughLiveVerdict() async throws {
        try requireLive()
        let model = ProcessInfo.processInfo.environment["VERDICT_MODEL"] ?? "verdict-fm"
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let router = VerdictSmartPasteRouter(
            transport: CoreAuthorizedVerdictTransport(core: core),
            model: model,
            // No deterministic floor, so every fill below is verdict's own decision.
            fallback: NoFloorRouter()
        )
        // A name and an organisation — the residue the deterministic floor leaves.
        let entities = [
            SmartPasteEntity(id: "e-name", kind: .name, value: "Dr. Priya Raman", raw: "Dr. Priya Raman"),
            SmartPasteEntity(id: "e-org", kind: .organization, value: "Atlas Robotics", raw: "Atlas Robotics"),
        ]
        let fields = [
            SmartPasteFieldDescriptor(id: "field-name", label: "Full name"),
            SmartPasteFieldDescriptor(id: "field-company", label: "Company or organisation"),
            SmartPasteFieldDescriptor(id: "field-city", label: "City"),
        ]
        let fills = try await router.route(entities: entities, into: fields)
        for fill in fills {
            print("PILOT [\(model)] \(fill.entityID) → \(fill.fieldID) "
                + "conf=\(fill.confidence) kind=\(fill.confidenceKind.rawValue)")
        }
        XCTAssertFalse(fills.isEmpty, "live verdict returned no routing; check the daemon and token")
        XCTAssertTrue(fills.allSatisfy { fill in
            ["field-name", "field-company", "field-city"].contains(fill.fieldID)
        })
    }
}

/// A router that places nothing, so a live pilot measures verdict's decisions alone.
private struct NoFloorRouter: SmartPasteRouter {
    func route(entities: [SmartPasteEntity], into fields: [SmartPasteFieldDescriptor]) async throws -> [SmartPasteFill] { [] }
}
