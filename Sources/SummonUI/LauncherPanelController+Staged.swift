import AppKit
import SummonCore

extension LauncherPanelController {
    func refreshStagedStrip() {
        do {
            let list = try session.core.staged.list(state: "staged")
            if let stagedID, list.contains(where: { $0.id == stagedID }) {
                stagedReviewView.isHidden = false
                return
            }
            if let first = list.first {
                if stagedID != first.id {
                    stagedID = first.id
                    if let presentation = try? StagedReviewPresentation(proposal: first) {
                        stagedReviewView.display(
                            title: presentation.title,
                            reviewedText: presentation.reviewedText
                        )
                    } else {
                        stagedReviewView.display(
                            title: "Staged (\(first.rung)) — repair the exact action before accepting",
                            reviewedText: first.output
                        )
                    }
                }
                stagedReviewView.isHidden = false
            } else {
                clearStagedChrome()
            }
        } catch {
            clearStagedChrome()
        }
    }

    private func clearStagedChrome() {
        stagedID = nil
        stagedReviewView.clear()
    }

    @objc func acceptStaged() {
        guard let id = stagedID else { return }
        guard let proposal = try? session.core.staged.get(id), proposal.state == "staged" else {
            refreshStagedStrip()
            applyLayout(animated: true)
            return
        }
        if proposal.rung == "agent" {
            acceptAgentProposal(id: id)
        } else {
            acceptTextProposal(id: id)
        }
        refreshStagedStrip()
        updateFooter()
        applyLayout(animated: true)
    }

    private func acceptAgentProposal(id: String) {
        do {
            let result = try session.core.acceptStagedAgentAction(
                id: id,
                reviewedOutput: stagedReviewView.reviewedText,
                actor: .user
            )
            switch result.outcome {
            case .applied:
                footerError = "Accepted"
            case .rejected(let reason):
                footerError = "Apply failed: \(reason)"
            case .staged(let proposalID):
                footerError = "Apply failed: restaged as \(proposalID)"
            }
        } catch {
            footerError = "Apply failed: \(error.localizedDescription)"
        }
    }

    private func acceptTextProposal(id: String) {
        do {
            let reviewedText = stagedReviewView.reviewedText
            try stagedTextWriter(reviewedText)
            try session.core.acceptStagedTextProposal(
                id: id,
                reviewedOutput: reviewedText,
                actor: .user
            )
            footerError = "Accepted"
        } catch {
            footerError = "Apply failed: \(error.localizedDescription)"
        }
    }

    @objc func rejectStaged() {
        guard let id = stagedID else { return }
        if let proposal = try? session.core.staged.get(id), proposal.rung == "agent" {
            do {
                try session.core.rejectStagedAgentAction(id: id, actor: .user)
                footerError = "Rejected"
            } catch {
                footerError = "Reject failed: \(error.localizedDescription)"
            }
        } else {
            do {
                try session.core.rejectStagedProposal(id: id, actor: .user)
                footerError = "Rejected"
            } catch {
                footerError = "Reject failed: \(error.localizedDescription)"
            }
        }
        refreshStagedStrip()
        updateFooter()
        applyLayout(animated: true)
    }
}
