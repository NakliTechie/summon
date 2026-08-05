import Foundation
import SummonCore

extension LauncherPanelController {
    func stageAI(_ confirmation: LauncherConfirmation) {
        guard let aiIntegration else {
            footerError = "AI is unavailable in this build"
            applyLayout(animated: false)
            return
        }
        let prompt = confirmation.result.payload["prompt"]?.stringValue ?? confirmation.query
        footerError = "AI: preparing a staged proposal"
        applyLayout(animated: false)

        let operation = Task.detached(priority: .userInitiated) {
            try await aiIntegration.stage(prompt: prompt)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let outcome = try await operation.value
                self.refreshStagedStrip()
                let egress = outcome.egressSummary.isEmpty
                    ? "nothing left this Mac"
                    : outcome.egressSummary
                self.footerError = "Staged via \(outcome.rung) · \(egress)"
                self.applyLayout(animated: true)
            } catch {
                self.footerError = L10n.t(.degradedAI)
                self.applyLayout(animated: true)
            }
        }
    }
}
