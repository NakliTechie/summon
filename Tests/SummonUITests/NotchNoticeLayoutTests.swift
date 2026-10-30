import XCTest
@testable import SummonUI

/// Geometry from the gate host (2026-10-30): a built-in Retina display with a
/// 32 pt notch, and an external 1920×1080 display without one.
final class NotchNoticeLayoutTests: XCTestCase {
    private let builtIn = CGRect(x: -1512, y: 98, width: 1512, height: 982)
    private let builtInVisible = CGRect(x: -1512, y: 98, width: 1512, height: 950)
    private let external = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let externalVisible = CGRect(x: 0, y: 90, width: 1920, height: 960)

    private var builtInNotch: CGRect? {
        NotchNoticeLayout.notchRect(
            frame: builtIn,
            safeAreaTop: 32,
            topLeftArea: CGRect(x: -1512, y: 1048, width: 663, height: 32),
            topRightArea: CGRect(x: -664, y: 1048, width: 664, height: 32)
        )
    }

    func testNotchRectSitsBetweenTheAreasEitherSide() throws {
        let notch = try XCTUnwrap(builtInNotch)
        XCTAssertEqual(notch, CGRect(x: -849, y: 1048, width: 185, height: 32))
        XCTAssertNil(NotchNoticeLayout.notchRect(
            frame: external, safeAreaTop: 0, topLeftArea: nil, topRightArea: nil
        ))
    }

    func testNoticeHangsFromTheNotchFlushWithTheTopEdge() throws {
        let notch = try XCTUnwrap(builtInNotch)
        let placement = NotchNoticeLayout.placement(
            content: CGSize(width: 300, height: 36),
            screenFrame: builtIn,
            visibleFrame: builtInVisible,
            notch: notch
        )
        XCTAssertEqual(placement.style, .notch)
        XCTAssertEqual(placement.frame.maxY, builtIn.maxY, "flush with the screen's top edge")
        XCTAssertEqual(placement.frame.midX, notch.midX, accuracy: 0.5, "centred on the notch")
        XCTAssertEqual(placement.frame.height, 32 + 36)
        XCTAssertEqual(placement.topInset, 32, "content starts below the notch")
    }

    func testShortNoticeIsStillWiderThanTheNotch() throws {
        let notch = try XCTUnwrap(builtInNotch)
        let placement = NotchNoticeLayout.placement(
            content: CGSize(width: 90, height: 36),
            screenFrame: builtIn,
            visibleFrame: builtInVisible,
            notch: notch
        )
        XCTAssertEqual(placement.frame.width, 185 + 2 * NotchNoticeLayout.shoulder)
    }

    func testScreenWithoutANotchGetsAPillBelowTheMenuBar() {
        let placement = NotchNoticeLayout.placement(
            content: CGSize(width: 300, height: 36),
            screenFrame: external,
            visibleFrame: externalVisible,
            notch: nil
        )
        XCTAssertEqual(placement.style, .pill)
        XCTAssertEqual(placement.frame.midX, externalVisible.midX, accuracy: 0.5)
        XCTAssertEqual(placement.frame.maxY, externalVisible.maxY - NotchNoticeLayout.pillGap)
        XCTAssertEqual(placement.topInset, 0)
    }

    func testWideNoticeStaysOnScreen() throws {
        let notch = try XCTUnwrap(builtInNotch)
        let placement = NotchNoticeLayout.placement(
            content: CGSize(width: 1600, height: 36),
            screenFrame: builtIn,
            visibleFrame: builtInVisible,
            notch: notch
        )
        XCTAssertGreaterThanOrEqual(placement.frame.minX, builtIn.minX + NotchNoticeLayout.sideMargin)
        XCTAssertLessThanOrEqual(placement.frame.maxX, builtIn.maxX - NotchNoticeLayout.sideMargin)

        let pill = NotchNoticeLayout.placement(
            content: CGSize(width: 2400, height: 36),
            screenFrame: external,
            visibleFrame: externalVisible,
            notch: nil
        )
        XCTAssertGreaterThanOrEqual(pill.frame.minX, externalVisible.minX + NotchNoticeLayout.sideMargin)
        XCTAssertLessThanOrEqual(pill.frame.maxX, externalVisible.maxX - NotchNoticeLayout.sideMargin)
    }
}
