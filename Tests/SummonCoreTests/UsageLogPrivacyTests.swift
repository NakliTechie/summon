import XCTest
@testable import SummonCore

/// The usage log must not hold clipboard text or values nothing accepted (Codex review 2026-11-02).
final class UsageLogPrivacyTests: XCTestCase {
    func testAClipboardRowLogsItsKindNotItsText() {
        XCTAssertEqual(UsageLog.loggableTitle("my secret token abc123", kind: .clipboard), "(clipboard item)")
        XCTAssertEqual(UsageLog.loggableTitle("System Settings", kind: .app), "System Settings")
    }

    func testAProposalNamesFieldsAndNeverShowsValues() {
        let fills = [
            SmartPasteFill(fieldID: "f1", entityID: "e1", value: "jane@example.com", confidence: 0.9,
                           confidenceKind: .heuristic, rationale: ""),
            SmartPasteFill(fieldID: "f2", entityID: "e2", value: "+14155550198", confidence: 0.9,
                           confidenceKind: .heuristic, rationale: ""),
        ]
        let labels = ["f1": "Email", "f2": "Phone"]
        let proposal = UsageLog.smartPasteSummary(fills: fills, labels: labels, applied: nil)
        XCTAssertEqual(proposal, "Email | Phone")
        let applied = UsageLog.smartPasteSummary(fills: fills, labels: labels, applied: ["f1"])
        XCTAssertEqual(applied, "Email=jane@example.com | Phone (not applied)")
    }
}
