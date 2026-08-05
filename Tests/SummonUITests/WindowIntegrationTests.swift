import ApplicationServices
import Carbon
import XCTest
@testable import SummonCore
@testable import SummonUI

final class WindowIntegrationTests: XCTestCase {
    func testStatusMenuSeparatesRegistrationFromAccessibility() {
        XCTAssertEqual(
            StatusMenuPresentation.windowShortcutsTitle(registered: 12, total: 13),
            "Window Shortcuts (12/13 Registered)"
        )
        XCTAssertEqual(
            StatusMenuPresentation.accessibilityTitle(isTrusted: false),
            "Accessibility Permission: Off"
        )
        XCTAssertEqual(
            StatusMenuPresentation.accessibilityTitle(isTrusted: true),
            "Accessibility Permission: On"
        )
    }

    func testCoordinateConversionUsesPrimaryDisplayOriginWhenDisplayIsAbovePrimary() {
        let primary = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let above = CGRect(x: 200, y: 1_080, width: 1_440, height: 900)
        let target = WindowGeometry.frame(layout: .topHalf, screen: above, gap: 8)

        let axFrame = WindowCoordinateSpace.axFrame(fromCocoaFrame: target, primaryFrame: primary)

        XCTAssertLessThan(axFrame.minY, 0)
        XCTAssertEqual(
            WindowCoordinateSpace.cocoaFrame(fromAXFrame: axFrame, primaryFrame: primary),
            target
        )
        XCTAssertNotEqual(axFrame.minY, primary.union(above).maxY - target.maxY)
    }

    func testFocusedWindowDisplaySelectionUsesLargestIntersection() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            CGRect(x: 1_920, y: 100, width: 1_440, height: 900),
        ]
        let mostlySecondary = CGRect(x: 1_800, y: 200, width: 900, height: 700)

        XCTAssertEqual(
            WindowCoordinateSpace.screenIndex(
                containingCocoaFrame: mostlySecondary,
                screenFrames: screens
            ),
            1
        )
    }

    func testFocusedWindowDisplaySelectionFallsBackToPrimary() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            CGRect(x: 1_920, y: 0, width: 1_440, height: 900),
        ]
        let offscreen = CGRect(x: -5_000, y: -5_000, width: 100, height: 100)

        XCTAssertEqual(
            WindowCoordinateSpace.screenIndex(
                containingCocoaFrame: offscreen,
                screenFrames: screens
            ),
            0
        )
    }

    func testAXErrorsExplainPermissionAndUnresponsiveTarget() {
        XCTAssertEqual(
            WindowApplicator.axErrorMessage(operation: "Window positioning", error: .apiDisabled),
            "Window positioning failed: Accessibility permission is off"
        )
        XCTAssertEqual(
            WindowApplicator.axErrorMessage(operation: "Window sizing", error: .cannotComplete),
            "Window sizing failed: the target application did not answer"
        )
    }

    func testWindowPolicyScopesActionsToFocusedWindowOnActiveSpace() {
        XCTAssertEqual(WindowApplicator.spaceBehavior, .focusedWindowOnActiveSpace)
    }

    func testFrameTransactionSizesBeforePositioning() throws {
        let original = CGRect(x: 400, y: 120, width: 900, height: 700)
        let target = CGRect(x: 1_920, y: 100, width: 700, height: 900)
        var writes: [(WindowFrameAttribute, CGRect)] = []

        try WindowApplicator.applyFrameTransaction(frame: target, originalFrame: original) { attribute, frame in
            writes.append((attribute, frame))
            return .success
        }

        XCTAssertEqual(writes.map(\.0), [.size, .position])
        XCTAssertEqual(writes.map(\.1), [target, target])
    }

    func testFrameTransactionRestoresOriginalFrameAfterPositionFailure() {
        let original = CGRect(x: 400, y: 120, width: 900, height: 700)
        let target = CGRect(x: 1_920, y: 100, width: 700, height: 900)
        var writes: [(WindowFrameAttribute, CGRect)] = []

        XCTAssertThrowsError(
            try WindowApplicator.applyFrameTransaction(frame: target, originalFrame: original) { attribute, frame in
                writes.append((attribute, frame))
                if attribute == .position, frame == target { return .cannotComplete }
                return .success
            }
        ) { error in
            XCTAssertTrue(String(describing: error).contains("the original frame was restored"))
        }
        XCTAssertEqual(writes.map(\.0), [.size, .position, .size, .position])
        XCTAssertEqual(writes.map(\.1), [target, target, original, original])
    }

    func testFrameTransactionReportsRestorationFailure() {
        let original = CGRect(x: 400, y: 120, width: 900, height: 700)
        let target = CGRect(x: 1_920, y: 100, width: 700, height: 900)

        XCTAssertThrowsError(
            try WindowApplicator.applyFrameTransaction(frame: target, originalFrame: original) { attribute, frame in
                if attribute == .position, frame == target { return .cannotComplete }
                if attribute == .size, frame == original { return .apiDisabled }
                return .success
            }
        ) { error in
            XCTAssertTrue(String(describing: error).contains("restoring the original frame also failed"))
            XCTAssertTrue(String(describing: error).contains("Accessibility permission is off"))
        }
    }

    func testDefaultWindowShortcutMapCoversEveryLayoutWithoutCollisions() {
        let shortcuts = WindowShortcut.defaults

        XCTAssertEqual(Set(shortcuts.map(\.layout)), Set(WindowLayout.allCases))
        XCTAssertEqual(Set(shortcuts.map(\.id)).count, shortcuts.count)
        XCTAssertEqual(
            Set(shortcuts.map { "\($0.keyCode):\($0.modifiers)" }).count,
            shortcuts.count
        )
        XCTAssertTrue(shortcuts.allSatisfy {
            $0.modifiers == UInt32(controlKey | optionKey)
        })
        XCTAssertTrue(shortcuts.allSatisfy { $0.menuTitle.contains($0.label) })
        XCTAssertEqual(Set(shortcuts.map(\.displayName)).count, shortcuts.count)
    }

    func testWindowShortcutProducesJournalableModuleAction() throws {
        let shortcut = try XCTUnwrap(WindowShortcut.defaults.first { $0.layout == .leftHalf })

        XCTAssertEqual(
            shortcut.action,
            .moduleRun(
                name: "window.arrange",
                targetID: "window:leftHalf",
                path: nil,
                payload: ["layout": .string("leftHalf"), "gap": .number(8)]
            )
        )
    }
}
