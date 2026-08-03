import AppKit
import ApplicationServices
import Foundation
import SummonCore

/// Applies `WindowGeometry` frames to the frontmost window via Accessibility.
public enum WindowApplicator {
    public static func ensurePermission() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    public static func apply(layout: WindowLayout, gap: CGFloat = 8) throws {
        guard AXIsProcessTrusted() else {
            throw CoreError.io("Accessibility permission required for window management")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw CoreError.io("no frontmost application")
        }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard err == .success, let window = windowRef else {
            throw CoreError.io("no focused window")
        }
        // AXUIElement is a CFType; bridge without force-cast operator.
        let axWindow = unsafeBitCast(window, to: AXUIElement.self)

        guard let screen = NSScreen.main?.visibleFrame else {
            throw CoreError.io("no main screen")
        }
        // Cocoa y is bottom-up; AX uses top-left. Convert.
        let screenCG = CGRect(
            x: screen.origin.x,
            y: screen.origin.y,
            width: screen.width,
            height: screen.height
        )
        let target = WindowGeometry.frame(layout: layout, screen: screenCG, gap: gap)

        var pos = CGPoint(x: target.minX, y: flipY(target.maxY, screen: screen))
        var size = CGSize(width: target.width, height: target.height)
        if let posVal = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal)
        }
    }

    private static func flipY(_ axTopY: CGFloat, screen: NSRect) -> CGFloat {
        // AX global y from top of main display; simplify using screen maxY
        let full = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        return full.height - axTopY
    }
}
