import GRDB
import XCTest
@testable import SummonCore

private final class HardenTarget: SmartPasteTarget {
    var descriptors: [SmartPasteFieldDescriptor]
    var rejectAll = false
    private(set) var writes: [(String, String)] = []
    init(_ descriptors: [SmartPasteFieldDescriptor] = []) { self.descriptors = descriptors }
    func fields() throws -> [SmartPasteFieldDescriptor] { descriptors }
    func apply(value: String, toFieldID id: String) throws -> Bool {
        if rejectAll { return false }
        writes.append((id, value)); return true
    }
}

private func hardenCore() throws -> SummonCore { try SummonCore.inMemory(appSearchPaths: []) }

private func stagedID(
    _ core: SummonCore, _ target: HardenTarget, _ text: String = "a@b.com and +1 415 555 0198"
) async throws -> String {
    let id = try await SmartPasteService().proposeAndStage(
        sourceText: text, target: target, router: DeterministicSmartPasteRouter(), store: core.staged
    )
    return try XCTUnwrap(id)
}

final class SmartPasteHardenTests: XCTestCase {
    private let fields = [
        SmartPasteFieldDescriptor(id: "field-0", label: "Email"),
        SmartPasteFieldDescriptor(id: "field-1", label: "Phone"),
    ]

    // X1 — duplicate field ids must not trap the review label map.
    func testFieldLabelsToleratesDuplicateIDs() {
        let dup = [
            SmartPasteFieldDescriptor(id: "f", label: "First"),
            SmartPasteFieldDescriptor(id: "f", label: "Second"),
        ]
        let labels = SmartPasteService.fieldLabels(for: dup)
        XCTAssertEqual(labels["f"], "First", "first occurrence wins; the constructor must not trap on the collision")
    }

    // B3 — oversized input is truncated, not stalled or crashed.
    func testExtractionBoundsHugeInput() {
        let huge = String(repeating: "x ", count: 200_000) + "tail@example.com"
        let entities = EntityExtractor().extract(from: huge)
        XCTAssertLessThanOrEqual(huge.prefix(EntityExtractor.maximumInputCharacters).count, EntityExtractor.maximumInputCharacters)
        XCTAssertTrue(entities.count <= 8, "a capped scan yields a bounded entity set")
    }

    // B8 — decoding a non-smart-paste proposal is refused, not silently coerced.
    func testProposalDecodeRejectsWrongRung() {
        let alien = PersistedStagedProposal(rung: "agent", prompt: "p", output: "{}")
        XCTAssertThrowsError(try SmartPasteService.proposal(from: alien))
    }

    // S2 — every fill rejected by the target transitions the proposal to apply_failed.
    func testAllFillsRejectedMarksApplyFailed() async throws {
        let core = try hardenCore()
        let target = HardenTarget(fields)
        let id = try await stagedID(core, target)
        target.rejectAll = true
        let outcomes = try core.acceptStagedSmartPaste(id: id, target: target, actor: .user)
        XCTAssertTrue(outcomes.allSatisfy { !$0.applied })
        XCTAssertEqual(try core.staged.get(id)?.state, "apply_failed")
    }

    // S3 + A2 — reject is user-gated and moves the proposal to rejected.
    func testRejectStagedSmartPasteIsUserGated() async throws {
        let core = try hardenCore()
        let target = HardenTarget(fields)
        let id = try await stagedID(core, target)
        XCTAssertThrowsError(try core.rejectStagedSmartPaste(id: id, actor: .agent))
        XCTAssertEqual(try core.staged.get(id)?.state, "staged", "an agent reject must not move the proposal")
        try core.rejectStagedSmartPaste(id: id, actor: .user)
        XCTAssertEqual(try core.staged.get(id)?.state, "rejected")
    }

    // S4 — accepting a proposal that is not staged (already terminal) is refused.
    func testAcceptAfterTerminalIsRefused() async throws {
        let core = try hardenCore()
        let target = HardenTarget(fields)
        let id = try await stagedID(core, target)
        _ = try core.acceptStagedSmartPaste(id: id, target: target, actor: .user) // → accepted
        XCTAssertThrowsError(try core.acceptStagedSmartPaste(id: id, target: target, actor: .user),
                             "a second accept must not re-apply")
    }

    // S5 — accepting an unknown id is refused.
    func testAcceptUnknownIDIsRefused() throws {
        let core = try hardenCore()
        XCTAssertThrowsError(try core.acceptStagedSmartPaste(id: "nope", target: HardenTarget(), actor: .user))
    }
}
