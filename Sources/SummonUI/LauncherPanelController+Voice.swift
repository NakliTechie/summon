import AppKit
import Foundation
import SummonCore

/// Voice into the launcher: the text heard so far replaces the query and searches as typed text
/// does, so date answers, apps and the AI offers all work the same. Nothing runs until Enter.
extension LauncherPanelController {
    public var isShowing: Bool { panel.isVisible }

    /// Shows "Listening…" in the empty field while the microphone is open.
    public func setListening(_ listening: Bool) {
        let text = listening ? "Listening… let go to stop" : L10n.t(.searchPlaceholder)
        let font = searchField.placeholderAttributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        searchField.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .foregroundColor: listening ? Tokens.System.accentText : Tokens.System.secondaryLabel,
            .font: font ?? NSFont.systemFont(ofSize: 22),
        ])
        if listening {
            footerError = nil
            applyLayout(animated: true)
        }
        UsageLog.record(listening ? "launcher.voice.listening" : "launcher.voice.stopped")
    }

    /// Puts the words heard so far in the field and searches them.
    public func showVoiceText(_ text: String) {
        guard text != searchField.stringValue else { return }
        searchField.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        searchField.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    /// Says why voice could not start (no microphone permission, no speech files), with the fix.
    public func showVoiceProblem(_ message: String) {
        setListening(false)
        footerError = message
        applyLayout(animated: true)
        UsageLog.record("launcher.voice.failed", ["reason": message])
    }
}
