import XCTest
@testable import SummonCore
@testable import SummonUI

final class FirstRunLoginChoiceTests: XCTestCase {
    func testDecideLaterLeavesLoginPromptEligible() {
        XCTAssertNil(FirstRunLoginChoice.decideLater.requestedEnabled)
        XCTAssertFalse(FirstRunLoginChoice.decideLater.marksPrompted)
        XCTAssertEqual(FirstRunLoginChoice.keepReady.requestedEnabled, true)
        XCTAssertTrue(FirstRunLoginChoice.keepReady.marksPrompted)
        XCTAssertEqual(FirstRunLoginChoice.notNow.requestedEnabled, false)
        XCTAssertTrue(FirstRunLoginChoice.notNow.marksPrompted)
    }

    func testLoginChoiceReportsRegistrationFailure() {
        let failed = LoginItemService.applyChoice(
            true,
            setter: { _ in false },
            observer: { true }
        )
        XCTAssertEqual(failed, .failed)

        let applied = LoginItemService.applyChoice(
            false,
            setter: { _ in true },
            observer: { false }
        )
        XCTAssertEqual(applied, .applied(observedEnabled: false))
    }

    func testLauncherSeenMarkerCanWaitUntilSheetCloses() throws {
        let core = try SummonCore.inMemory(appSearchPaths: [])
        let controller = LauncherPanelController(core: core)
        controller.show(markFirstRunSeen: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(try core.settings.get(LauncherStarterCatalog.firstRunSeenKey))

        controller.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(
            try core.settings.get(LauncherStarterCatalog.firstRunSeenKey),
            .bool(true)
        )
        controller.hide()
    }
}
