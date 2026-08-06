import AppKit
import XCTest
import SummonCore
@testable import SummonUI

final class LauncherQuickActionsTests: XCTestCase {
    func testEmptyStateIsBareThenRightArrowRevealsAndActivatesQuickActions() throws {
        var navigated: AppDestination?
        let panel = LauncherPanelController(
            core: try SummonCore.inMemory(),
            onNavigate: { navigated = $0 }
        )
        panel.show(markFirstRunSeen: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        defer { panel.hide() }

        // Spotlight-bare: no starter list dumped, strip hidden.
        XCTAssertTrue(panel.session.results.isEmpty)
        XCTAssertTrue(panel.quickActionStrip.isHidden)
        XCTAssertFalse(panel.quickActionsShown)

        // → reveals the strip.
        XCTAssertNil(panel.handleFocusedKey(try key(panel, keyCode: 124))) // right arrow
        XCTAssertTrue(panel.quickActionsShown)

        // ⌘1 activates the first quick action (Clipboard History).
        XCTAssertNil(panel.handleFocusedKey(
            try key(panel, keyCode: 18, command: true, chars: "1")
        ))
        XCTAssertEqual(navigated, LauncherQuickActionStrip.actions.first?.destination)
    }

    func testTypingSupersedesTheQuickActionStrip() throws {
        let panel = LauncherPanelController(core: try SummonCore.inMemory())
        panel.show(markFirstRunSeen: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        defer { panel.hide() }

        panel.revealQuickActions()
        XCTAssertTrue(panel.quickActionsShown)

        panel.searchField.stringValue = "fi"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertFalse(panel.quickActionsShown)
    }

    private func key(
        _ panel: LauncherPanelController,
        keyCode: UInt16,
        command: Bool = false,
        chars: String = ""
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: command ? .command : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.panel.windowNumber,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
