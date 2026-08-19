import AppKit
import XCTest
@testable import SummonCore
@testable import SummonUI

/// Regression for "web search did nothing": a modal (web-search consent /
/// destructive confirm) steals key focus, so `windowDidResignKey` queued a 0.08s
/// `hide()` that drained inside the modal loop and tore the panel down. The result
/// then rendered into an already-hidden panel. `withResignHideSuppressed` guards it.
final class LauncherModalResignHideTests: XCTestCase {
    func testResignHideSuppressedFlagSetsDuringBodyAndRestoresAfter() throws {
        let controller = LauncherPanelController(core: try SummonCore.inMemory())
        controller.show()
        // show() sets the flag true and clears it on the next main-loop turn.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        defer { controller.hide() }

        XCTAssertFalse(controller.suppressResignHide)
        var observedInside = false
        controller.withResignHideSuppressed {
            observedInside = controller.suppressResignHide
        }
        XCTAssertTrue(observedInside, "flag must be set while the modal body runs")
        XCTAssertFalse(controller.suppressResignHide, "flag must restore after the modal")
    }

    func testResignKeyDuringSuppressedModalDoesNotHidePanel() throws {
        let controller = LauncherPanelController(core: try SummonCore.inMemory())
        controller.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        defer { controller.hide() }
        XCTAssertTrue(controller.panel.isVisible)

        // Simulate the modal: while suppressed, the panel resigns key (the alert
        // took it). Post the exact notification the auto-hide observes, then let
        // the run loop drain past the 0.08s hide deadline.
        controller.withResignHideSuppressed {
            NotificationCenter.default.post(
                name: NSWindow.didResignKeyNotification,
                object: controller.panel
            )
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }

        XCTAssertTrue(
            controller.panel.isVisible,
            "a resign-key during a suppressed modal must not hide the panel"
        )
    }
}
