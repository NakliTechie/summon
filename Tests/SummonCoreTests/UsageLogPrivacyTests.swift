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
        XCTAssertEqual(applied, "Email (applied) | Phone (not applied)")
        XCTAssertFalse(applied.contains("jane@example.com"), "no value is ever logged")
    }

    func testTheLogIsOffUnlessAskedFor() {
        XCTAssertFalse(UsageLog.enabled(environment: [:], defaultsSetting: false, underTest: false), "off by default")
        XCTAssertTrue(UsageLog.enabled(environment: [:], defaultsSetting: true, underTest: false), "defaults write turns it on")
        XCTAssertTrue(UsageLog.enabled(environment: ["SUMMON_USAGE_LOG": "1"], defaultsSetting: false, underTest: false))
        XCTAssertTrue(UsageLog.enabled(environment: ["SUMMON_USAGE_LOG": "/tmp/x.jsonl"], defaultsSetting: false, underTest: false))
        let off = ["SUMMON_USAGE_LOG": "0"]
        XCTAssertFalse(UsageLog.enabled(environment: off, defaultsSetting: true, underTest: false), "0 forces it off")
        let on = ["SUMMON_USAGE_LOG": "1"]
        XCTAssertFalse(UsageLog.enabled(environment: on, defaultsSetting: true, underTest: true), "never under XCTest")
    }
}
