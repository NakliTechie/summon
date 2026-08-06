import AppKit
import Foundation
import SummonCore

extension LauncherPanelController {
    /// Invoke the local AI for the confirmed "Ask local AI" offer. A plain-text
    /// answer is shown read-only (answer shape); a machine action is staged for
    /// Accept/Reject (staged shape). Nothing here auto-executes.
    func runAI(_ confirmation: LauncherConfirmation) {
        guard let aiIntegration else {
            footerError = "AI is unavailable in this build"
            applyLayout(animated: false)
            return
        }
        let prompt = confirmation.result.payload["prompt"]?.stringValue ?? confirmation.query
        footerError = "AI: thinking on-device…"
        applyLayout(animated: false)

        let operation = Task.detached(priority: .userInitiated) {
            try await aiIntegration.respond(prompt: prompt)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch try await operation.value {
                case let .answer(text, rung, egress):
                    self.presentAIAnswer(text: text, rung: rung, egress: egress)
                case let .staged(_, rung, egress):
                    self.refreshStagedStrip()
                    let e = egress.isEmpty ? "nothing left this Mac" : egress
                    self.footerError = "Staged via \(rung) · \(e)"
                    self.applyLayout(animated: true)
                }
            } catch {
                self.footerError = L10n.t(.degradedAI)
                self.applyLayout(animated: true)
            }
        }
    }

    /// Show a read-only answer. It replaces the offer row and carries no Accept gate.
    func presentAIAnswer(text: String, rung: String, egress: String) {
        let egressNote = egress.isEmpty ? "nothing left this Mac" : egress
        session.applyResults(searchField.stringValue, [])
        aiAnswerView.display(title: "Answer · \(rung) · \(egressNote)", answer: text)
        footerError = nil
        applyLayout(animated: true)
    }

    func dismissAIAnswer() {
        aiAnswerView.clear()
        footerError = nil
        applyLayout(animated: true)
    }

    @objc func copyAnswer() {
        do {
            try stagedTextWriter(aiAnswerView.answer)
            footerError = "Copied"
        } catch {
            footerError = "Copy failed: \(error.localizedDescription)"
        }
        applyLayout(animated: true)
    }

    /// Copy the answer and dismiss the launcher so focus returns to the prior app
    /// for an immediate ⌘V. (Direct auto-paste is a deferred follow-up.)
    @objc func insertAnswer() {
        try? stagedTextWriter(aiAnswerView.answer)
        hide()
    }

    /// Search the web and answer (harness-driven). First use asks consent; on a
    /// grounded result the read-only answer card shows the summary + its sources.
    func runWebSearch(_ confirmation: LauncherConfirmation, allowOnce: Bool = false) {
        guard let aiIntegration else {
            footerError = "AI is unavailable in this build"
            applyLayout(animated: false)
            return
        }
        let prompt = confirmation.result.payload["prompt"]?.stringValue ?? confirmation.query
        footerError = "Searching the web…"
        applyLayout(animated: false)

        let operation = Task.detached(priority: .userInitiated) {
            try await aiIntegration.search(prompt: prompt, allowOnce: allowOnce)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch try await operation.value {
                case let .answer(text, sources, rung):
                    let body = sources.isEmpty
                        ? text
                        : text + "\n\nSources:\n" + sources.map { "· \($0)" }.joined(separator: "\n")
                    self.presentAIAnswer(text: body, rung: "\(rung) · web", egress: "query sent to the web")
                case let .needsConsent(host):
                    self.promptWebConsent(host: host, confirmation: confirmation)
                case .noResults:
                    self.footerError = "No web results for that"
                    self.applyLayout(animated: true)
                case .unavailable:
                    self.footerError = "Web search is unavailable"
                    self.applyLayout(animated: true)
                }
            } catch {
                self.footerError = L10n.t(.degradedAI)
                self.applyLayout(animated: true)
            }
        }
    }

    private func promptWebConsent(host: String, confirmation: LauncherConfirmation) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Search the web?"
        alert.informativeText = "Your query will be sent to \(host). "
            + "The answer is composed on this Mac — nothing else leaves."
        alert.addButton(withTitle: "Always Allow")
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Don't Allow")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            aiIntegration?.grantSearchConsent(always: true)
            runWebSearch(confirmation, allowOnce: true)
        case .alertSecondButtonReturn:
            runWebSearch(confirmation, allowOnce: true)
        default:
            footerError = "Web search declined"
            applyLayout(animated: true)
        }
    }
}
