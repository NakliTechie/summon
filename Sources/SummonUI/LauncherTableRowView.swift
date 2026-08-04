import AppKit

/// Selection chrome that follows system accent / unemphasized selection (HIG list rows).
final class LauncherTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        didSet { needsDisplay = true }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let inset = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(
            roundedRect: inset,
            xRadius: Tokens.Metrics.rowCornerRadius,
            yRadius: Tokens.Metrics.rowCornerRadius
        )
        if isEmphasized {
            // Soft accent wash — readable on vibrancy materials in light and dark.
            Tokens.System.accent.withAlphaComponent(0.22).setFill()
        } else {
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        }
        path.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent so NSVisualEffectView shows through.
    }
}
