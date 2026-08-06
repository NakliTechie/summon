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
}
