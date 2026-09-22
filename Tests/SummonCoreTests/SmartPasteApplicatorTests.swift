import XCTest
@testable import SummonCore

/// A fake target: records writes, can reject a field, or throw for one.
private final class RecordingFieldTarget: SmartPasteTarget {
    var descriptors: [SmartPasteFieldDescriptor]
    var rejecting: Set<String> = []      // apply returns false
    var throwing: Set<String> = []       // apply throws
    private(set) var writes: [(String, String)] = []

    init(descriptors: [SmartPasteFieldDescriptor] = []) {
        self.descriptors = descriptors
    }

    func fields() throws -> [SmartPasteFieldDescriptor] { descriptors }

    func apply(value: String, toFieldID id: String) throws -> Bool {
        if throwing.contains(id) { throw CoreError.io("field \(id) is gone") }
        if rejecting.contains(id) { return false }
        writes.append((id, value))
        return true
    }
}

private func proposal(_ fills: [SmartPasteFill]) -> SmartPasteProposal {
    SmartPasteProposal(sourceText: "src", entities: [], fills: fills, generatedBy: "test")
}

private func fill(_ fieldID: String, _ value: String) -> SmartPasteFill {
    SmartPasteFill(
        fieldID: fieldID, entityID: "e-\(fieldID)", value: value,
        confidence: 0.9, confidenceKind: .heuristic, rationale: "test"
    )
}

final class SmartPasteApplicatorTests: XCTestCase {
    func testAppliesAllFillsWhenNoAcceptSubsetGiven() {
        let target = RecordingFieldTarget()
        let outcomes = SmartPasteApplicator().apply(
            proposal([fill("f1", "a@b.com"), fill("f2", "555")]),
            to: target
        )
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy(\.applied))
        XCTAssertEqual(target.writes.map(\.0), ["f1", "f2"])
    }

    func testOnlyAcceptedFieldsAreWritten() {
        let target = RecordingFieldTarget()
        let outcomes = SmartPasteApplicator().apply(
            proposal([fill("f1", "a@b.com"), fill("f2", "555")]),
            acceptedFieldIDs: ["f1"],
            to: target
        )
        XCTAssertEqual(outcomes.count, 1, "a rejected proposal fill is never written or reported as applied")
        XCTAssertEqual(target.writes.map(\.0), ["f1"])
    }

    func testRejectedFieldReportsNotApplied() {
        let target = RecordingFieldTarget()
        target.rejecting = ["f1"]
        let outcomes = SmartPasteApplicator().apply(proposal([fill("f1", "x")]), to: target)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(outcomes[0].applied)
        XCTAssertTrue(target.writes.isEmpty)
        XCTAssertEqual(outcomes[0].detail, "the field did not accept the value")
    }

    func testThrownErrorIsCapturedAsNotApplied() {
        let target = RecordingFieldTarget()
        target.throwing = ["f1"]
        let outcomes = SmartPasteApplicator().apply(proposal([fill("f1", "x"), fill("f2", "y")]), to: target)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertFalse(outcomes[0].applied)
        XCTAssertTrue(outcomes[1].applied, "one field's failure does not stop the rest")
        XCTAssertEqual(target.writes.map(\.0), ["f2"])
    }
}
