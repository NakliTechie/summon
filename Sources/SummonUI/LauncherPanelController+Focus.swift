import AppKit

extension LauncherPanelController {
    public func controlTextDidBeginEditing(_ obj: Notification) {
        updateSearchFocusState()
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        updateSearchFocusState()
    }

    func updateSearchFocusState() {
        let editor = searchField.currentEditor()
        let responder = panel.firstResponder
        let hasFocus = panel.isVisible
            && (responder === searchField || responder === editor)
        searchFocusView.isHidden = !hasFocus
        searchIconView.contentTintColor = hasFocus
            ? Tokens.System.accent
            : Tokens.System.secondaryLabel
    }

    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible, panel.isKeyWindow || NSApp.keyWindow === panel else {
            return event
        }
        return handleFocusedKey(event)
    }

    func handleFocusedKey(_ event: NSEvent) -> NSEvent? {
        let editor = searchField.currentEditor() as? NSTextView
        let stagedEditorFocused = stagedReviewView.containsFirstResponder(panel.firstResponder)
        let markedText = editor?.hasMarkedText() == true
            || (stagedEditorFocused && stagedReviewView.editorHasMarkedText)
        if markedText, [36, 125, 126].contains(event.keyCode) {
            return event
        }

        if !stagedReviewView.isHidden {
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "e" {
                _ = stagedReviewView.focusEditor(in: panel)
                return nil
            }
            if event.keyCode == 36 {
                acceptStaged()
                return nil
            }
            if event.keyCode == 53 {
                rejectStaged()
                return nil
            }
            if stagedEditorFocused {
                return event
            }
        }

        if !aiAnswerView.isHidden {
            if event.keyCode == 53 { // Esc dismisses the answer
                dismissAIAnswer()
                return nil
            }
            // Selecting/copying inside the answer text takes precedence over shortcuts.
            if aiAnswerView.containsFirstResponder(panel.firstResponder) {
                return event
            }
            if event.keyCode == 36 { // Enter inserts (copy + close)
                insertAnswer()
                return nil
            }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                copyAnswer()
                return nil
            }
        }

        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "k" {
            if session.objectMode { session.exitObjectMode() } else { session.enterObjectMode() }
            applyLayout(animated: false)
            return nil
        }

        switch event.keyCode {
        case 125:
            session.moveSelection(by: 1)
            applyLayout(animated: false)
            return nil
        case 126:
            session.moveSelection(by: -1)
            applyLayout(animated: false)
            return nil
        case 36:
            let hasQuery = !searchField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            let hasResults = !session.results.isEmpty || session.objectMode
            if hasQuery || hasResults { confirmSelection() }
            return nil
        case 48:
            if session.objectMode { session.exitObjectMode() } else { session.enterObjectMode() }
            applyLayout(animated: false)
            return nil
        case 53:
            if session.objectMode {
                session.exitObjectMode()
                applyLayout(animated: false)
            } else if !searchField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty {
                searchField.stringValue = ""
                controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            } else {
                hide()
            }
            return nil
        default:
            let editing = panel.firstResponder === searchField
                || panel.firstResponder === searchField.currentEditor()
            if !editing {
                let chars = event.charactersIgnoringModifiers ?? ""
                let printable = chars.contains {
                    $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " "
                }
                if printable { _ = panel.makeFirstResponder(searchField) }
            }
            return event
        }
    }
}
