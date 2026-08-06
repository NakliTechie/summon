import AppKit
import Foundation
import SummonCore

extension LauncherPanelController {
    /// Native inline creation form for snippets / quicklinks (create.* actions).
    /// Intercepted from `confirmSelection` because creation needs user input the
    /// headless action bus cannot supply.
    func presentCreate(_ confirmation: LauncherConfirmation) {
        let isSnippet = confirmation.actionName == "create.snippet"
        let seed = confirmation.result.payload["seedName"]?.stringValue ?? ""

        let nameField = NSTextField(string: seed)
        nameField.placeholderString = "Name"
        let valueField = NSTextField(string: "")
        valueField.placeholderString = isSnippet ? "Body" : "URL (https://…)"
        let keywordField = NSTextField(string: "")
        keywordField.placeholderString = "Keyword (optional)"

        let width: CGFloat = 288, rowH: CGFloat = 24, gap: CGFloat = 9
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: rowH * 3 + gap * 2))
        for (index, field) in [nameField, valueField, keywordField].enumerated() {
            field.frame = NSRect(x: 0, y: (rowH + gap) * CGFloat(2 - index), width: width, height: rowH)
            container.addSubview(field)
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isSnippet ? "New snippet" : "New quicklink"
        alert.informativeText = isSnippet
            ? "Name and body are required; keyword is optional."
            : "Name and URL are required; keyword is optional."
        alert.accessoryView = container
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = seed.isEmpty ? nameField : valueField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = valueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywordRaw = keywordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !value.isEmpty else {
            footerError = isSnippet ? "Snippet needs a name and body" : "Quicklink needs a name and URL"
            applyLayout(animated: false)
            return
        }
        let keyword = keywordRaw.isEmpty ? nil : keywordRaw
        let action: CoreAction = isSnippet
            ? .snippetUpsert(id: UUID().uuidString, name: name, body: value, keyword: keyword)
            : .quicklinkUpsert(id: UUID().uuidString, name: name, url: value, keyword: keyword)
        do {
            let outcome = try session.core.dispatch(action: action, actor: .user)
            guard outcome.isApplied else {
                footerError = "Create was not applied"
                applyLayout(animated: false)
                return
            }
            hide()
        } catch {
            footerError = (error as? CoreError)?.message ?? error.localizedDescription
            applyLayout(animated: false)
        }
    }
}
