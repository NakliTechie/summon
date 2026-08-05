import XCTest
@testable import SummonCore

final class FTSConsentTests: XCTestCase {
    func testEnableWithoutConsentFails() throws {
        let core = try SummonCore.inMemory()
        XCTAssertThrowsError(try core.setFTSEnabled(true))
        XCTAssertFalse(core.search.ftsEnabled)
    }

    func testEnableAfterConsent() throws {
        let core = try SummonCore.inMemory()
        try core.grantFTSConsent()
        try core.setFTSEnabled(true)
        XCTAssertTrue(core.search.ftsEnabled)
        try core.setFTSEnabled(false)
        XCTAssertFalse(core.search.ftsEnabled)
    }

    func testDisableDeletesIndexedBodies() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        try core.grantFTSConsent()
        try core.setFTSEnabled(true)
        try core.fts.upsert(FTSDocument(
            id: "private-doc",
            title: "Private",
            body: "fts-private-marker-6281",
            path: "/private/doc.txt"
        ))
        XCTAssertEqual(try core.fts.count(), 1)

        try core.setFTSEnabled(false)

        XCTAssertFalse(core.search.ftsEnabled)
        XCTAssertEqual(try core.fts.count(), 0)
    }

    func testFTSConfigurationIsJournaledAndRawSettingBypassIsRejected() throws {
        let core = try SummonCore.inMemory()
        try core.grantFTSConsent()

        try core.setFTSEnabled(true)
        let bypass = try core.dispatch(
            action: .settingsSet(key: "search.fts.enabled", value: .bool(false)),
            actor: .user
        )

        XCTAssertFalse(bypass.isApplied)
        XCTAssertEqual(try core.settings.get("search.fts.enabled"), .bool(true))
        XCTAssertEqual(try core.journal.allEntries().map(\.action.name), [
            "fts.consent.grant",
            "fts.setEnabled",
            "settings.set",
        ])
    }

    func testConsentGrantIsActorAttributedAndTerminal() throws {
        let core = try SummonCore.inMemory()

        try core.grantFTSConsent(actor: .user)

        let entry = try XCTUnwrap(try core.journal.allEntries().last)
        XCTAssertEqual(entry.actor, .user)
        XCTAssertEqual(entry.action, .ftsConsentGrant)
        XCTAssertEqual(entry.outcome, "applied")
        XCTAssertTrue(core.ftsConsentGranted())
    }

    func testReplayRestoresFTSEnabledStateWithoutReauthorizingConsent() throws {
        let core = try SummonCore.inMemory()
        try core.grantFTSConsent()
        try core.setFTSEnabled(true)

        let replayed = try core.replayedCopy()

        XCTAssertEqual(try replayed.settings.get("search.fts.enabled"), .bool(true))
        XCTAssertTrue(replayed.search.ftsEnabled)
        XCTAssertFalse(replayed.ftsConsentGranted())
    }

    func testStartupIgnoresEnabledSettingWhenConsentFileIsAbsent() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("summon-fts-startup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let queue = try SummonDatabase.open(in: container)
        try SettingsStore(dbQueue: queue).set("search.fts.enabled", value: .bool(true))

        let core = SummonCore(
            dbQueue: queue,
            containerURL: container,
            spotlight: FakeSpotlightIndex(),
            executor: RecordingModuleExecutor()
        )

        XCTAssertFalse(core.search.ftsEnabled)
        XCTAssertTrue(core.startupWarnings.contains { $0.contains("consent is absent") })
    }

    func testAgentFTSConfigurationStagesUntilUserAccepts() throws {
        let core = try SummonCore.inMemory()
        try core.grantFTSConsent()

        let staged = try core.dispatch(action: .ftsSetEnabled(enabled: true), actor: .agent)
        XCTAssertTrue(staged.isStaged)
        XCTAssertFalse(core.search.ftsEnabled)

        let proposalID = try XCTUnwrap(staged.stagedProposalID)
        let output = try XCTUnwrap(try core.staged.get(proposalID)?.output)
        let accepted = try core.acceptStagedAgentAction(
            id: proposalID,
            reviewedOutput: output,
            actor: .user
        )
        XCTAssertTrue(accepted.isApplied)
        XCTAssertTrue(core.search.ftsEnabled)
    }

    func testSensitiveSearchFlagGatesFTSBody() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        try core.grantFTSConsent()
        try core.setFTSEnabled(true)
        try core.fts.upsert(FTSDocument(
            id: "sensitive-doc",
            title: "Sensitive title",
            body: "private-token-9437",
            path: "/private/document.txt"
        ))

        let denied = try core.search.search(
            "private-token-9437",
            includeSensitiveStores: false
        )
        let granted = try core.search.search(
            "private-token-9437",
            includeSensitiveStores: true
        )

        XCTAssertFalse(denied.contains { $0.id == "fts:sensitive-doc" })
        XCTAssertTrue(granted.contains { $0.id == "fts:sensitive-doc" })
    }
}
