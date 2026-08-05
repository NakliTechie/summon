import Foundation

public enum StatusMenuPresentation {
    public static func windowShortcutsTitle(registered: Int, total: Int) -> String {
        "Window Shortcuts (\(registered)/\(total) Registered)"
    }

    public static func accessibilityTitle(isTrusted: Bool) -> String {
        isTrusted ? "Accessibility Permission: On" : "Accessibility Permission: Off"
    }
}
