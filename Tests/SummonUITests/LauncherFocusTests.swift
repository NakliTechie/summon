import AppKit
import XCTest
@testable import SummonCore
@testable import SummonUI

final class LauncherFocusTests: XCTestCase {
    func testRenderedLauncherExposesVisibleAccessibleKeyboardFocus() throws {
        let controller = LauncherPanelController(core: try SummonCore.inMemory())
        controller.show()
        pumpMainRunLoop()
        defer { controller.hide() }

        let content = try XCTUnwrap(controller.panel.contentView)
        let searchField = try XCTUnwrap(
            descendants(of: content)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityLabel() == "Search" }
        )
        let focusView = try XCTUnwrap(
            descendants(of: content).first {
                $0.identifier?.rawValue == "summon.search.focus"
            }
        )

        XCTAssertTrue(controller.panel.firstResponder === searchField.currentEditor())
        XCTAssertFalse(focusView.isHidden)
        XCTAssertEqual(searchField.accessibilityRole(), .textField)
        XCTAssertEqual(searchField.accessibilitySubrole(), .searchField)
        XCTAssertEqual(searchField.accessibilityHelp(), "Type to search Summon")
        XCTAssertGreaterThanOrEqual(focusView.layer?.borderWidth ?? 0, 2)
        XCTAssertNotNil(focusView.layer?.borderColor)

        let png = try renderedPNG(of: content)
        XCTAssertGreaterThan(png.count, 1_000)
        if let destination = ProcessInfo.processInfo.environment["SUMMON_FOCUS_SNAPSHOT"] {
            try png.write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
    }

    func testTabEntersObjectActionsWithoutLosingSearchFocus() throws {
        let controller = LauncherPanelController(core: try SummonCore.inMemory())
        controller.show()
        pumpMainRunLoop()
        defer { controller.hide() }

        // The empty state is Spotlight-bare; supply a query result to navigate.
        controller.searchField.stringValue = "q"
        controller.session.applyResults("q", [
            SearchResult(id: "one", title: "One", kind: .command),
        ])
        pumpMainRunLoop()

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.panel.windowNumber,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ))
        XCTAssertNil(controller.handleFocusedKey(event))
        pumpMainRunLoop()

        XCTAssertTrue(controller.session.objectMode)
        let searchField = try XCTUnwrap(
            descendants(of: controller.panel.contentView)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityLabel() == "Search" }
        )
        XCTAssertTrue(controller.panel.firstResponder === searchField.currentEditor())
        let focusView = try XCTUnwrap(
            descendants(of: controller.panel.contentView).first {
                $0.identifier?.rawValue == "summon.search.focus"
            }
        )
        XCTAssertFalse(focusView.isHidden)
    }

    func testArrowKeysMoveLauncherSelectionAndAreConsumed() throws {
        let controller = LauncherPanelController(core: try SummonCore.inMemory())
        controller.show()
        pumpMainRunLoop()
        defer { controller.hide() }

        // The empty state is Spotlight-bare; supply query results to navigate.
        controller.searchField.stringValue = "q"
        controller.session.applyResults("q", [
            SearchResult(id: "one", title: "One", kind: .command),
            SearchResult(id: "two", title: "Two", kind: .command),
        ])
        pumpMainRunLoop()

        XCTAssertGreaterThan(controller.session.results.count, 1)
        XCTAssertEqual(controller.session.selectedIndex, 0)

        let down = try keyEvent(controller: controller, keyCode: 125, characters: "")
        XCTAssertNil(controller.handleFocusedKey(down))
        XCTAssertEqual(controller.session.selectedIndex, 1)

        let up = try keyEvent(controller: controller, keyCode: 126, characters: "")
        XCTAssertNil(controller.handleFocusedKey(up))
        XCTAssertEqual(controller.session.selectedIndex, 0)
    }

    func testStagedKeyboardRoutesAcceptEditRejectAndEditorNavigation() throws {
        let acceptedCore = try SummonCore.inMemory()
        let acceptedID = UUID().uuidString
        try acceptedCore.staged.upsert(PersistedStagedProposal(
            id: acceptedID,
            rung: "L0",
            prompt: "accept",
            output: "original"
        ))
        var writtenText: String?
        let acceptedController = LauncherPanelController(
            core: acceptedCore,
            stagedTextWriter: { writtenText = $0 }
        )
        acceptedController.show()
        pumpMainRunLoop()
        defer { acceptedController.hide() }
        acceptedController.stagedReviewView.reviewedText = "reviewed"

        let edit = try keyEvent(
            controller: acceptedController,
            keyCode: 14,
            characters: "e",
            modifiers: .command
        )
        XCTAssertNil(acceptedController.handleFocusedKey(edit))
        XCTAssertTrue(acceptedController.stagedReviewView.containsFirstResponder(
            acceptedController.panel.firstResponder
        ))

        let down = try keyEvent(
            controller: acceptedController,
            keyCode: 125,
            characters: ""
        )
        let tab = try keyEvent(
            controller: acceptedController,
            keyCode: 48,
            characters: "\t"
        )
        XCTAssertNotNil(acceptedController.handleFocusedKey(down))
        XCTAssertNotNil(acceptedController.handleFocusedKey(tab))
        XCTAssertFalse(acceptedController.session.objectMode)

        let accept = try keyEvent(
            controller: acceptedController,
            keyCode: 36,
            characters: "\r"
        )
        XCTAssertNil(acceptedController.handleFocusedKey(accept))
        XCTAssertEqual(writtenText, "reviewed")
        XCTAssertEqual(try acceptedCore.staged.get(acceptedID)?.state, "accepted")

        let rejectedCore = try SummonCore.inMemory()
        let rejectedID = UUID().uuidString
        try rejectedCore.staged.upsert(PersistedStagedProposal(
            id: rejectedID,
            rung: "L0",
            prompt: "reject",
            output: "reject me"
        ))
        let rejectedController = LauncherPanelController(
            core: rejectedCore,
            stagedTextWriter: { _ in }
        )
        rejectedController.show()
        pumpMainRunLoop()
        defer { rejectedController.hide() }
        let escape = try keyEvent(
            controller: rejectedController,
            keyCode: 53,
            characters: "\u{1b}"
        )
        XCTAssertNil(rejectedController.handleFocusedKey(escape))
        XCTAssertEqual(try rejectedCore.staged.get(rejectedID)?.state, "rejected")
    }

    private func keyEvent(
        controller: LauncherPanelController,
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.panel.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func pumpMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    private func descendants(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { descendants(of: $0) }
    }

    private func renderedPNG(of view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}
