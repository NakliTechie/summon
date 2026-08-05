import XCTest
@testable import SummonCore

final class CLIActorPolicyTests: XCTestCase {
    func testAgentFaceRequiresExplicitEnabledSetting() {
        XCTAssertNoThrow(
            try CLIActorPolicy.authorizeAgentFace(actor: .user, enabledValue: nil)
        )
        XCTAssertThrowsError(
            try CLIActorPolicy.authorizeAgentFace(actor: .agent, enabledValue: nil)
        )
        XCTAssertThrowsError(
            try CLIActorPolicy.authorizeAgentFace(actor: .agent, enabledValue: .bool(false))
        )
        XCTAssertNoThrow(
            try CLIActorPolicy.authorizeAgentFace(actor: .agent, enabledValue: .bool(true))
        )
    }

    func testAgentCLIAuditActionCarriesActorAndCommand() throws {
        let core = try SummonCore.inMemory()
        let result = try core.dispatch(action: .agentCLI(command: "settings.get"), actor: .agent)
        XCTAssertTrue(result.isApplied)
        let entry = try XCTUnwrap(core.journal.allEntries().last)
        XCTAssertEqual(entry.actor, .agent)
        XCTAssertEqual(entry.action, .agentCLI(command: "settings.get"))
    }

    func testEveryDirectPrivilegedOperationRejectsAgentAndAllowsUser() {
        XCTAssertFalse(CLIPrivilegedOperation.allCases.isEmpty)
        for operation in CLIPrivilegedOperation.allCases {
            XCTAssertNoThrow(try CLIActorPolicy.authorize(actor: .user, operation: operation))
            XCTAssertThrowsError(
                try CLIActorPolicy.authorize(actor: .agent, operation: operation),
                "agent reached \(operation.rawValue)"
            )
            XCTAssertThrowsError(
                try CLIActorPolicy.authorize(actor: .ext(id: "probe"), operation: operation),
                "extension reached \(operation.rawValue)"
            )
        }
    }
}
