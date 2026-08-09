import AppKit
import SummonCore

/// Launcher footer: the keyboard-hint line plus the non-blocking status slots
/// (accessibility hint, web-search setup progress). Split out of the controller
/// to keep it under the length gate; the members it touches are module-internal.
extension LauncherPanelController {
    func refreshPermissionHint() {
        let snap = PermissionStatus.snapshot()
        permissionHint = snap.accessibilityTrusted ? nil : "Accessibility off"
        updateFooter()
    }

    /// Show (or clear, with nil) a non-blocking web-search setup status in the footer.
    public func showWebSearchStatus(_ text: String?) {
        webSearchStatus = text
        updateFooter()
    }

    func updateFooter() {
        guard showResultsChrome else {
            footerLabel.stringValue = ""
            return
        }
        var parts = ["↩ Open"]
        if !aiAnswerView.isHidden {
            parts = ["↩ Insert", "⌘C Copy", "Esc Dismiss"]
        } else if session.objectMode {
            parts = ["↩ Run", "Esc Back"]
        }
        if let err = footerError, !err.isEmpty {
            parts.append(err)
        } else if let hint = permissionHint {
            parts.append(hint)
        }
        if let status = webSearchStatus, !status.isEmpty {
            parts.append(status)
        }
        parts.append("v\(SummonVersion.string)")
        footerLabel.stringValue = parts.joined(separator: "  ·  ")
    }
}
