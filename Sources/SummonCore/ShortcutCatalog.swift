import Foundation

/// User-facing labels for app-level shortcuts. The app sets the labels it registered, so text
/// built after launch names the shortcut the user chose in Settings; before that, the defaults.
public enum ShortcutCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active: [SummonShortcut: String] = [:] // guarded by `lock`

    public static func setActiveLabels(_ labels: [SummonShortcut: String]) {
        lock.lock()
        active = labels
        lock.unlock()
    }

    public static func label(_ shortcut: SummonShortcut) -> String {
        lock.lock()
        defer { lock.unlock() }
        return active[shortcut] ?? shortcut.defaultBinding?.label ?? "none"
    }

    public static var launcher: String { label(.launcher) }
    public static var clipboardHistory: String { label(.clipboardHistory) }
    public static var smartPaste: String { label(.smartPaste) }
    public static let clearClipboardHistory = "⌘⇧⌫"
}
