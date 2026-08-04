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
        let axWindow = unsafeBitCast(window, to: AXUIElement.self)

        let screenFrame = activeScreenVisibleFrame(for: app)
        let screenCG = CGRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y,
            width: screenFrame.width,
            height: screenFrame.height
        )
        let target = WindowGeometry.frame(layout: layout, screen: screenCG, gap: gap)

        var pos = CGPoint(x: target.minX, y: flipY(target.maxY))
        var size = CGSize(width: target.width, height: target.height)

        guard let posVal = AXValueCreate(.cgPoint, &pos) else {
            throw CoreError.io("AX position value create failed")
        }
        let posErr = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal)
        guard posErr == .success else {
            throw CoreError.io("AX set position failed (\(posErr.rawValue))")
        }

        guard let sizeVal = AXValueCreate(.cgSize, &size) else {
            throw CoreError.io("AX size value create failed")
        }
        let sizeErr = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal)
        guard sizeErr == .success else {
            throw CoreError.io("AX set size failed (\(sizeErr.rawValue))")
        }
    }

    /// Prefer the screen containing the mouse, then main.
    public static func activeScreenVisibleFrame(for app: NSRunningApplication? = nil) -> NSRect {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen.visibleFrame
        }
        if let main = NSScreen.main {
            return main.visibleFrame
        }
        return NSScreen.screens.first?.visibleFrame ?? .zero
    }

    /// AX global y from top of the display union.
    private static func flipY(_ axTopY: CGFloat) -> CGFloat {
        let full = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        return full.maxY - axTopY
    }
}
