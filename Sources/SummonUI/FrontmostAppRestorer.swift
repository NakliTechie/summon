#if canImport(AppKit)
import AppKit

/// Remembers the app that was frontmost when a Summon surface opened, and returns
/// focus to it on dismiss — so a copied emoji / clipboard item / result lands in
/// the app you were using, ready to paste. Capture just before Summon activates
/// itself; restore right after ordering the window out. "Open app/file" actions
/// still win because they re-activate their target after the restore.
public final class FrontmostAppRestorer {
    private var previousApp: NSRunningApplication?

    public init() {}

    /// Record the current frontmost app (unless it's Summon itself).
    public func capture() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        previousApp = front
    }

    /// Reactivate the remembered app, if it's still running.
    public func restore() {
        let app = previousApp
        previousApp = nil
        guard let app, !app.isTerminated else { return }
        app.activate()
    }
}
#endif
