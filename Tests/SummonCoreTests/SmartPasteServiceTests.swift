import GRDB
import XCTest
@testable import SummonCore

private final class FakeTarget: SmartPasteTarget {
    var descriptors: [SmartPasteFieldDescriptor]
    private(set) var writes: [(String, String)] = []

    init(_ descriptors: [SmartPasteFieldDescriptor]) { self.descriptors = descriptors }
    func fields() throws -> [SmartPasteFieldDescriptor] { descriptors }
    func apply(value: String, toFieldID id: String) throws -> Bool {
        writes.append((id, value)); return true
    }
}

private func makeStore() throws -> StagedProposalStore {
    let store = StagedProposalStore(dbQueue: try DatabaseQueue())
    try store.migrate()
    return store
}

final class SmartPasteServiceTests: XCTestCase {
    private let contact = "Jane Doe\njane.doe@example.com\n+1 (415) 555-0198"
    private let fields = [
        SmartPasteFieldDescriptor(id: "field-0", label: "Email"),
        SmartPasteFieldDescriptor(id: "field-1", label: "Phone"),
    ]

    func testProposeExtractsAndRoutesEndToEnd() async throws {
        let proposal = try await SmartPasteService().propose(
            sourceText: contact, fields: fields, router: DeterministicSmartPasteRouter()
        )
        XCTAssertEqual(proposal.generatedBy, "deterministic")
        XCTAssertEqual(Set(proposal.fills.map(\.fieldID)), ["field-0", "field-1"])
    }

    func testProposeYieldsEmptyWhenNoFieldsMatch() async throws {
        let proposal = try await SmartPasteService().propose(
            sourceText: contact,
            fields: [SmartPasteFieldDescriptor(id: "x", label: "Favourite colour")],
            router: DeterministicSmartPasteRouter()
        )
        XCTAssertTrue(proposal.isEmpty)
        XCTAssertEqual(proposal.generatedBy, "none")
    }

    func testProposeAndStagePersistsAReviewableProposal() async throws {
        let store = try makeStore()
        let target = FakeTarget(fields)
        let id = try await SmartPasteService().proposeAndStage(
            sourceText: contact, target: target, router: DeterministicSmartPasteRouter(), store: store
        )
        let staged = try XCTUnwrap(id)
        let listed = try store.list(state: "staged")
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, staged)
        XCTAssertEqual(listed.first?.rung, SmartPasteService.rung)
        XCTAssertTrue(target.writes.isEmpty, "staging never writes to the target")
    }

    func testNothingIsStagedWhenThereIsNoConfidentFill() async throws {
        let store = try makeStore()
        let id = try await SmartPasteService().proposeAndStage(
            sourceText: contact,
            target: FakeTarget([SmartPasteFieldDescriptor(id: "x", label: "Favourite colour")]),
            router: DeterministicSmartPasteRouter(),
            store: store
        )
        XCTAssertNil(id)
        XCTAssertTrue(try store.list(state: "staged").isEmpty)
    }

    func testAcceptStagedSmartPasteWritesFillsAndJournalsTheDecision() async throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let target = FakeTarget(fields)
        let service = SmartPasteService()
        let staged = try await service.proposeAndStage(
            sourceText: contact, target: target, router: DeterministicSmartPasteRouter(), store: core.staged
        )
        let id = try XCTUnwrap(staged)
        let outcomes = try core.acceptStagedSmartPaste(id: id, target: target, actor: .user)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy(\.applied))
        XCTAssertEqual(Set(target.writes.map(\.0)), ["field-0", "field-1"])
        XCTAssertEqual(try core.staged.get(id)?.state, "accepted")
        XCTAssertTrue(try core.staged.list(state: "staged").isEmpty)
    }

    func testAcceptStagedSmartPasteHonoursAnAcceptedSubset() async throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let target = FakeTarget(fields)
        let service = SmartPasteService()
        let staged = try await service.proposeAndStage(
            sourceText: contact, target: target, router: DeterministicSmartPasteRouter(), store: core.staged
        )
        let id = try XCTUnwrap(staged)
        let outcomes = try core.acceptStagedSmartPaste(
            id: id, acceptedFieldIDs: ["field-0"], target: target, actor: .user
        )
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(target.writes.map(\.0), ["field-0"])
        XCTAssertEqual(try core.staged.get(id)?.state, "accepted")
    }

    func testAcceptStagedSmartPasteRejectsNonUserActor() async throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let target = FakeTarget(fields)
        let staged = try await SmartPasteService().proposeAndStage(
            sourceText: contact, target: target, router: DeterministicSmartPasteRouter(), store: core.staged
        )
        let id = try XCTUnwrap(staged)
        XCTAssertThrowsError(try core.acceptStagedSmartPaste(id: id, target: target, actor: .agent))
        XCTAssertTrue(target.writes.isEmpty, "an agent actor never triggers an AX write")
    }

    func testBridgeRoundTripsTheProposal() throws {
        let original = SmartPasteProposal(
            sourceText: "src",
            entities: [SmartPasteEntity(id: "e", kind: .email, value: "a@b.com", raw: "a@b.com")],
            fills: [SmartPasteFill(
                fieldID: "f", entityID: "e", value: "a@b.com",
                confidence: 0.95, confidenceKind: .heuristic, rationale: "match"
            )],
            generatedBy: "deterministic"
        )
        let persisted = try SmartPasteService.persisted(from: original)
        XCTAssertEqual(persisted.rung, SmartPasteService.rung)
        let recovered = try SmartPasteService.proposal(from: persisted)
        XCTAssertEqual(recovered, original)
    }
}
