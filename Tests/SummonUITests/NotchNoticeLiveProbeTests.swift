import AppKit
import XCTest
@testable import SummonUI

/// Shows a real notice on every attached display and reads its bounds back from
/// the window server, so placement is checked on actual hardware, not only in
/// the geometry tests. Gated: `SUMMON_RUN_NOTICE_LIVE=1 swift test --filter
/// NotchNoticeLiveProbeTests` on a Mac with a display session.
@MainActor
final class NotchNoticeLiveProbeTests: XCTestCase {
    func testNoticeLandsWhereTheLayoutSaysOnEveryScreen() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SUMMON_RUN_NOTICE_LIVE"] == "1",
            "Set SUMMON_RUN_NOTICE_LIVE=1 on a Mac with a display session."
        )
        _ = NSApplication.shared
        let primaryHeight = try XCTUnwrap(NSScreen.screens.first).frame.height
        for screen in NSScreen.screens {
            let notice = NotchNotice()
            notice.show(message: "Filled Email, Phone", actionTitle: "Undo", action: {}, duration: 5, on: screen)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let frame = try XCTUnwrap(notice.currentFrame, screen.localizedName)
            let number = try XCTUnwrap(notice.currentWindowNumber)
            let info = try XCTUnwrap(
                (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number))
                    as? [[String: Any]])?.first,
                "window server has no record of the notice"
            )
            let bounds = try XCTUnwrap(info[kCGWindowBounds as String] as? [String: CGFloat])
            // Window-server bounds use a top-left origin on the primary display.
            let serverRect = CGRect(
                x: bounds["X"] ?? .nan,
                y: primaryHeight - (bounds["Y"] ?? .nan) - (bounds["Height"] ?? .nan),
                width: bounds["Width"] ?? .nan,
                height: bounds["Height"] ?? .nan
            )
            let notch = NotchNoticeLayout.notchRect(
                frame: screen.frame,
                safeAreaTop: screen.safeAreaInsets.top,
                topLeftArea: screen.auxiliaryTopLeftArea,
                topRightArea: screen.auxiliaryTopRightArea
            )
            print("live notice on \(screen.localizedName): style=\(notch == nil ? "pill" : "notch") "
                + "appkit=\(frame) server=\(serverRect) layer=\(info[kCGWindowLayer as String] ?? "?")")

            // The window server reports a borderless panel 2 pt narrower on each
            // side than AppKit's frame, so compare centres and top edges.
            XCTAssertEqual(serverRect.midX, frame.midX, accuracy: 1, screen.localizedName)
            XCTAssertEqual(serverRect.maxY, frame.maxY, accuracy: 1, screen.localizedName)
            XCTAssertEqual(serverRect.width, frame.width, accuracy: 4, screen.localizedName)
            XCTAssertTrue(screen.frame.contains(serverRect), "\(screen.localizedName): notice off screen")
            if let notch {
                XCTAssertEqual(serverRect.maxY, screen.frame.maxY, accuracy: 1, "flush with the top edge")
                XCTAssertEqual(serverRect.midX, notch.midX, accuracy: 1, "centred on the notch")
            } else {
                XCTAssertLessThanOrEqual(serverRect.maxY, screen.visibleFrame.maxY, "below the menu bar")
            }
            notice.dismiss()
        }
    }
}
