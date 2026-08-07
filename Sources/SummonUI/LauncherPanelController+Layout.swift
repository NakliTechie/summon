import AppKit

extension LauncherPanelController {
    /// Lay out the mutually-stacked content bands (staged action, answer card,
    /// loading orb) below the search band and return the new content top.
    func layoutContentBands(top: CGFloat, inset: CGFloat) -> CGFloat {
        var contentTop = top
        if !stagedReviewView.isHidden {
            contentTop -= stagedBandHeight
            stagedReviewView.frame = NSRect(
                x: inset, y: contentTop, width: panelWidth - inset * 2, height: stagedBandHeight
            )
        }
        if !aiAnswerView.isHidden {
            contentTop -= answerBandHeight
            aiAnswerView.frame = NSRect(
                x: inset, y: contentTop, width: panelWidth - inset * 2, height: answerBandHeight
            )
        }
        if showingSpinner {
            contentTop -= spinnerBandHeight
            let orbSize: CGFloat = 40
            orbSpinner.frame = NSRect(
                x: (panelWidth - orbSize) / 2,
                y: contentTop + (spinnerBandHeight - orbSize) / 2,
                width: orbSize, height: orbSize
            )
            orbSpinner.isHidden = false
        } else {
            orbSpinner.isHidden = true
        }
        return contentTop
    }
}
