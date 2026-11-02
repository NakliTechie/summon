import AppKit
import Foundation
import SummonCore

extension LauncherPanelController {
    // MARK: - Search

    public func controlTextDidChange(_ obj: Notification) {
        let text = searchField.stringValue
        aiAnswerView.clear() // a new query dismisses any shown answer
        showingSpinner = false
        orbSpinner.stop()
        quickActionsShown = false // typing supersedes the quick-action strip
        searchGeneration &+= 1
        let generation = searchGeneration
        confirmWhenSearchLands = false // a keystroke after Enter withdraws that Enter
        searchDebounceWork?.cancel()

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchResultsPending = false
            confirmWhenSearchLands = false
            didPrewarm = false
            loadEmptyResults(firstRun: false)
            footerError = nil
            applyLayout(animated: true)
            return
        }

        // Preload the model on the first keystroke of a query so the first Enter is
        // faster — before, the model was only touched after Enter.
        if !didPrewarm, let ai = aiIntegration {
            ai.prewarm()
            didPrewarm = true
        }

        searchResultsPending = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.searchGeneration == generation else { return }
            self.searchQueue.async {
                // Typing outpaces a slow search: skip one a later keystroke has superseded.
                guard self.searchGeneration == generation else {
                    UsageLog.record("launcher.search.skipped", ["query": text])
                    return
                }
                let span = UsageLog.span("launcher.search", ["query": text])
                do {
                    var list = try self.session.computeResults(for: text)
                    if list.isEmpty, let ai = self.aiIntegration {
                        list = ai.offers(for: text)
                    }
                    ResultIcon.preload(list)
                    let top = list.first.map { UsageLog.loggableTitle($0.title, kind: $0.kind) } ?? ""
                    span.end(["count": String(list.count), "top": top])
                    DispatchQueue.main.async {
                        guard self.searchGeneration == generation else { return }
                        self.session.applyResults(text, list)
                        self.footerError = nil
                        self.applyLayout(animated: true)
                        self.searchLanded()
                    }
                } catch {
                    span.fail(error)
                    let message = (error as? CoreError)?.message ?? error.localizedDescription
                    DispatchQueue.main.async {
                        guard self.searchGeneration == generation else { return }
                        // The rows on screen belong to an older query: clear them so no Enter can run one.
                        self.session.applyResults(text, [])
                        self.footerError = message
                        self.applyLayout(animated: true)
                        self.searchLanded(runDeferredEnter: false)
                    }
                }
            }
        }
        searchDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(searchDebounceNs) / 1e9, execute: work)
    }

    func loadEmptyResults(firstRun: Bool) {
        // Spotlight-bare empty state: no dumped list. Quick actions live in the
        // →-revealed chip strip; the starter catalog is retained for other callers.
        _ = firstRun
        session.applyResults("", [])
    }

    func cancelPendingSearch() {
        searchGeneration &+= 1
        searchDebounceWork?.cancel()
        searchDebounceWork = nil
        searchResultsPending = false
        confirmWhenSearchLands = false
    }

    /// The results for what is in the field are on screen; run an Enter that waited for them.
    func searchLanded(runDeferredEnter: Bool = true) {
        searchResultsPending = false
        guard confirmWhenSearchLands else { return }
        confirmWhenSearchLands = false
        guard runDeferredEnter else {
            UsageLog.record("launcher.confirm.dropped", ["reason": "search failed"])
            return
        }
        UsageLog.record("launcher.confirm.deferred", ["query": searchField.stringValue])
        confirmSelection()
    }
}
