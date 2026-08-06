import AppKit

extension LauncherPanelController {
    func revealQuickActions() {
        guard !quickActionsShown else {
            quickActionStrip.move(by: 1)
            return
        }
        quickActionsShown = true
        quickActionStrip.select(index: 0)
        applyLayout(animated: true)
    }

    func hideQuickActions() {
        guard quickActionsShown else { return }
        quickActionsShown = false
        applyLayout(animated: true)
    }

    /// Handle keys for the →-revealed quick-action strip. Returns true when it
    /// consumes the event. Active only over an empty query, so it never
    /// intercepts search typing.
    func handleQuickActionKey(_ event: NSEvent) -> Bool {
        guard searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if event.modifierFlags.contains(.command),
           let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
           digit >= 1, digit <= quickActionStrip.count {
            quickActionStrip.activate(index: digit - 1)
            return true
        }
        if quickActionsShown {
            switch event.keyCode {
            case 124: // →
                quickActionStrip.move(by: 1)
                return true
            case 123: // ←
                if quickActionStrip.selectedIndex == 0 {
                    hideQuickActions()
                } else {
                    quickActionStrip.move(by: -1)
                }
                return true
            case 36: // ↩
                quickActionStrip.activateSelected()
                return true
            case 53: // Esc
                hideQuickActions()
                return true
            default:
                return false
            }
        }
        if event.keyCode == 124 { // → reveals the strip
            revealQuickActions()
            return true
        }
        return false
    }

    /// Lay out the chip strip when shown; return the width the search field
    /// should take so it stops before the strip.
    func layoutQuickActionStrip(
        bandY: CGFloat,
        inset: CGFloat,
        fieldStartX: CGFloat,
        defaultWidth: CGFloat
    ) -> CGFloat {
        guard quickActionsShown else {
            quickActionStrip.isHidden = true
            return defaultWidth
        }
        let stripWidth = quickActionStrip.intrinsicWidth
        let stripX = panelWidth - inset - stripWidth
        quickActionStrip.frame = NSRect(
            x: stripX, y: bandY, width: stripWidth, height: searchBandHeight
        )
        quickActionStrip.isHidden = false
        return max(40, stripX - 12 - fieldStartX)
    }
}
