import AppKit
import Foundation
import SummonCore

/// Spotlight-style launcher: compact search bar until the user types, then expands for results.
public final class LauncherPanelController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public let session: LauncherSession
    public let panel: KeyablePanel
    let aiIntegration: LauncherAIIntegration?
    let onNavigate: ((AppDestination) -> Void)?

    private let rootView: AppearanceAwareView
    private var effectView: NSVisualEffectView?
    let searchFocusView: NSView
    /// Leading magnifying glass (separate from the text field so they never overlap).
    let searchIconView: NSImageView
    let searchField: NSTextField
    private let searchDivider: NSBox
    private let scrollView: NSScrollView
    private let tableView: NSTableView
    private let emptyLabel: NSTextField
    let stagedReviewView: StagedReviewView
    let aiAnswerView: AIAnswerView
    let quickActionStrip: LauncherQuickActionStrip
    var quickActionsShown = false
    let stagedTextWriter: (String) throws -> Void
    private let footerLabel: NSTextField

    let panelWidth: CGFloat = 680
    /// Spotlight-like single-line bar.
    private let collapsedHeight: CGFloat = 48
    let searchBandHeight: CGFloat = 48
    private let maxResultsHeight: CGFloat = 380
    private let footerHeight: CGFloat = 22
    private let stagedBandHeight: CGFloat = 148
    // Dynamic: the answer card grows to fit its text (up to the cap, then scrolls).
    var answerBandHeight: CGFloat = 148
    let maxAnswerBandHeight: CGFloat = 460

    var stagedID: String?
    var footerError: String?
    private var permissionHint: String?
    private var resignHideWork: DispatchWorkItem?
    private var suppressResignHide = false
    private var searchGeneration: UInt64 = 0
    private let searchQueue = DispatchQueue(label: "summon.launcher.search", qos: .userInitiated)
    private let confirmationQueue = DispatchQueue(label: "summon.launcher.confirm", qos: .userInitiated)
    private var searchDebounceWork: DispatchWorkItem?
    private var stagedRefreshMonitor: StagedProposalRefreshMonitor?
    private let searchDebounceNs: UInt64 = 40_000_000
    private var eventMonitor: Any?

    // swiftlint:disable:next function_body_length
    public init(
        core: SummonCore,
        aiIntegration: LauncherAIIntegration? = nil,
        onNavigate: ((AppDestination) -> Void)? = nil,
        stagedTextWriter: @escaping (String) throws -> Void = {
            try PasteboardService.writeGeneratedText($0)
        }
    ) {
        self.session = LauncherSession(core: core)
        self.aiIntegration = aiIntegration
        self.onNavigate = onNavigate
        self.stagedTextWriter = stagedTextWriter

        let rect = NSRect(x: 0, y: 0, width: panelWidth, height: collapsedHeight)
        panel = KeyablePanel(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.appearance = nil

        rootView = AppearanceAwareView(frame: rect)
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = 12
        if #available(macOS 11.0, *) {
            rootView.layer?.cornerCurve = .continuous
        }
        rootView.layer?.masksToBounds = true
        rootView.layer?.borderWidth = 0.5
        panel.contentView = rootView

        let effect = NSVisualEffectView(frame: rootView.bounds)
        effect.autoresizingMask = [.width, .height]
        // Closest stock material to Spotlight chrome.
        effect.material = .headerView
        effect.blendingMode = .behindWindow
        effect.state = .active
        rootView.addSubview(effect, positioned: .below, relativeTo: nil)
        effectView = effect

        searchFocusView = NSView(frame: .zero)
        searchFocusView.identifier = NSUserInterfaceItemIdentifier("summon.search.focus")
        searchFocusView.wantsLayer = true
        searchFocusView.layer?.cornerRadius = 8
        searchFocusView.layer?.borderWidth = 2
        searchFocusView.isHidden = true
        rootView.addSubview(searchFocusView)

        // Icon + plain text field, shared vertical center in the search band.
        searchIconView = NSImageView(frame: .zero)
        searchIconView.imageScaling = .scaleProportionallyUpOrDown
        searchIconView.contentTintColor = Tokens.System.secondaryLabel
        if let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            searchIconView.image = img.withSymbolConfiguration(cfg)
        }
        rootView.addSubview(searchIconView)

        let searchFont = NSFont.systemFont(ofSize: 20, weight: .regular)
        searchField = NSTextField(frame: .zero)
        searchField.cell = VerticallyCenteredTextFieldCell(textCell: "")
        searchField.font = searchFont
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.backgroundColor = .clear
        searchField.textColor = Tokens.System.label
        searchField.alignment = .left
        searchField.maximumNumberOfLines = 1
        searchField.lineBreakMode = .byTruncatingTail
        searchField.usesSingleLineMode = true
        searchField.placeholderAttributedString = NSAttributedString(
            string: L10n.t(.searchPlaceholder),
            attributes: [
                .foregroundColor: Tokens.System.secondaryLabel,
                .font: searchFont,
            ]
        )
        searchField.setAccessibilityRole(.textField)
        searchField.setAccessibilitySubrole(.searchField)
        searchField.setAccessibilityLabel("Search")
        searchField.setAccessibilityHelp("Type to search Summon")
        rootView.addSubview(searchField)

        searchDivider = NSBox(frame: .zero)
        searchDivider.boxType = .separator
        searchDivider.isHidden = true
        rootView.addSubview(searchDivider)

        stagedReviewView = StagedReviewView(frame: .zero)
        stagedReviewView.isHidden = true
        rootView.addSubview(stagedReviewView)

        aiAnswerView = AIAnswerView(frame: .zero)
        aiAnswerView.isHidden = true
        rootView.addSubview(aiAnswerView)

        quickActionStrip = LauncherQuickActionStrip(frame: .zero)
        quickActionStrip.isHidden = true
        rootView.addSubview(quickActionStrip)

        scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.isHidden = true

        tableView = NSTableView(frame: .zero)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 40
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        if #available(macOS 11.0, *) {
            tableView.style = .plain
        }
        tableView.allowsEmptySelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.setAccessibilityRole(.list)
        tableView.setAccessibilityLabel("Search results")
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.width = panelWidth - 16
        tableView.addTableColumn(col)
        scrollView.documentView = tableView
        rootView.addSubview(scrollView)

        emptyLabel = NSTextField(labelWithString: "No Results")
        emptyLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        emptyLabel.textColor = Tokens.System.secondaryLabel
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        rootView.addSubview(emptyLabel)

        footerLabel = NSTextField(labelWithString: "")
        footerLabel.font = Tokens.TypeScale.footnote
        footerLabel.textColor = Tokens.System.tertiaryLabel
        footerLabel.alignment = .center
        footerLabel.isHidden = true
        rootView.addSubview(footerLabel)

        super.init()

        rootView.appearanceDidChange = { [weak self] in self?.refreshAppearance() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        refreshAppearance()

        searchField.delegate = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(confirmSelection)
        tableView.target = self
        stagedReviewView.acceptButton.target = self
        stagedReviewView.acceptButton.action = #selector(acceptStaged)
        stagedReviewView.rejectButton.target = self
        stagedReviewView.rejectButton.action = #selector(rejectStaged)
        aiAnswerView.copyButton.target = self
        aiAnswerView.copyButton.action = #selector(copyAnswer)
        aiAnswerView.insertButton.target = self
        aiAnswerView.insertButton.action = #selector(insertAnswer)
        quickActionStrip.onActivate = { [weak self] in self?.onNavigate?($0) }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: panel
        )
        stagedRefreshMonitor = StagedProposalRefreshMonitor { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.refreshStagedStrip()
            self.applyLayout(animated: true)
        }

        refreshPermissionHint()
        applyLayout(animated: false)
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Show / hide

    public func show(
        query initialQuery: String = "",
        markFirstRunSeen: Bool = true
    ) {
        cancelPendingSearch()
        let firstRun = (try? session.core.settings.get(LauncherStarterCatalog.firstRunSeenKey))?.boolValue != true
        searchField.stringValue = initialQuery
        if initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loadEmptyResults(firstRun: firstRun)
        } else {
            session.applyResults(initialQuery, [])
        }
        footerError = nil
        refreshPermissionHint()
        refreshStagedStrip()
        stagedRefreshMonitor?.startPolling()
        applyLayout(animated: false)
        positionOnActiveScreen()

        suppressResignHide = true
        resignHideWork?.cancel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.makeKey()
            _ = self.panel.makeFirstResponder(self.searchField)
            self.updateSearchFocusState()
            self.suppressResignHide = false
            if firstRun, markFirstRunSeen {
                _ = try? self.session.core.dispatch(
                    action: .settingsSet(
                        key: LauncherStarterCatalog.firstRunSeenKey,
                        value: .bool(true)
                    ),
                    actor: .system
                )
            }
            if !initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            }
        }
    }

    public func hide() {
        resignHideWork?.cancel()
        cancelPendingSearch()
        stagedRefreshMonitor?.stopPolling()
        searchField.stringValue = ""
        session.applyResults("", [])
        aiAnswerView.clear()
        quickActionsShown = false
        panel.orderOut(nil)
        updateSearchFocusState()
    }

    public func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    @objc private func windowDidResignKey(_ note: Notification) {
        updateSearchFocusState()
        guard !suppressResignHide else { return }
        resignHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.panel.isVisible, !self.panel.isKeyWindow {
                self.hide()
            }
        }
        resignHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    @objc private func windowDidBecomeKey(_ note: Notification) {
        updateSearchFocusState()
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else {
            panel.center()
            return
        }
        let vis = screen.visibleFrame
        let h = panel.frame.height
        // Spotlight sits upper-center of the active display.
        let x = vis.midX - panelWidth / 2
        let y = vis.midY + vis.height * 0.12 - h / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Spotlight compact layout

    private var hasQuery: Bool { !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var hasBrowsableResults: Bool { !session.results.isEmpty || session.objectMode }

    private var showResultsChrome: Bool {
        hasQuery || hasBrowsableResults || !stagedReviewView.isHidden
            || !aiAnswerView.isHidden || footerError != nil
    }

    private func targetHeight() -> CGFloat {
        var h = searchBandHeight
        if !stagedReviewView.isHidden {
            h += stagedBandHeight
        }
        if !aiAnswerView.isHidden {
            h += answerBandHeight
        }
        // The answer band replaces the results list; suppress the list while it shows.
        if hasQuery || hasBrowsableResults, aiAnswerView.isHidden {
            let rows = CGFloat(
                session.objectMode ? session.objectActions.count : session.results.count
            )
            if rows == 0 {
                h += 56 // "No Results" strip
            } else {
                let listH = min(maxResultsHeight, rows * tableView.rowHeight + 8)
                h += listH
            }
        }
        if showResultsChrome { h += footerHeight }
        return max(collapsedHeight, h)
    }

    func applyLayout(animated: Bool) {
        let height = targetHeight()
        let expanded = showResultsChrome

        let apply = {
            // Keep top edge stable when expanding (Spotlight grows downward).
            let old = self.panel.frame
            let top = old.maxY
            var frame = old
            frame.size.height = height
            frame.size.width = self.panelWidth
            frame.origin.y = top - height
            self.panel.setFrame(frame, display: true)

            self.rootView.frame = NSRect(x: 0, y: 0, width: self.panelWidth, height: height)
            self.effectView?.frame = self.rootView.bounds

            let inset: CGFloat = 16
            let iconSize: CGFloat = 20
            let bandY = height - self.searchBandHeight
            self.searchFocusView.frame = NSRect(
                x: 8,
                y: bandY + 6,
                width: self.panelWidth - 16,
                height: self.searchBandHeight - 12
            )
            // Shared vertical center for icon + text (optical mid of the 48pt bar).
            let rowH: CGFloat = 28
            let rowY = bandY + (self.searchBandHeight - rowH) / 2
            self.searchIconView.frame = NSRect(
                x: inset,
                y: rowY + (rowH - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            let textX = inset + iconSize + 10
            // Right-side quick-action chip strip (Macaw-style), shown on → over
            // an empty query; it shrinks the field to make room.
            let fieldWidth = self.layoutQuickActionStrip(
                bandY: bandY,
                inset: inset,
                fieldStartX: textX,
                defaultWidth: self.panelWidth - textX - inset
            )
            self.searchField.frame = NSRect(
                x: textX,
                y: rowY,
                width: fieldWidth,
                height: rowH
            )

            let dividerY = height - self.searchBandHeight
            self.searchDivider.frame = NSRect(x: 0, y: dividerY, width: self.panelWidth, height: 1)
            self.searchDivider.isHidden = !expanded

            var contentTop = dividerY
            if !self.stagedReviewView.isHidden {
                contentTop -= self.stagedBandHeight
                self.stagedReviewView.frame = NSRect(
                    x: inset,
                    y: contentTop,
                    width: self.panelWidth - inset * 2,
                    height: self.stagedBandHeight
                )
            }
            if !self.aiAnswerView.isHidden {
                contentTop -= self.answerBandHeight
                self.aiAnswerView.frame = NSRect(
                    x: inset,
                    y: contentTop,
                    width: self.panelWidth - inset * 2,
                    height: self.answerBandHeight
                )
            }

            let footerOn = expanded
            self.footerLabel.isHidden = !footerOn
            if footerOn {
                self.footerLabel.frame = NSRect(
                    x: inset,
                    y: 4,
                    width: self.panelWidth - inset * 2,
                    height: 14
                )
            }

            let resultsBottom: CGFloat = footerOn ? self.footerHeight : 0
            let resultsHeight = max(0, contentTop - resultsBottom)
            self.scrollView.isHidden = !expanded || self.session.results.isEmpty && !self.session.objectMode
            self.scrollView.frame = NSRect(
                x: 4,
                y: resultsBottom,
                width: self.panelWidth - 8,
                height: resultsHeight
            )

            let noHits = expanded
                && self.session.results.isEmpty
                && !self.session.objectMode
                && self.hasQuery
                && self.aiAnswerView.isHidden
            self.emptyLabel.isHidden = !noHits
            if noHits {
                self.emptyLabel.frame = NSRect(
                    x: inset,
                    y: resultsBottom + (resultsHeight - 18) / 2,
                    width: self.panelWidth - inset * 2,
                    height: 18
                )
            }

            self.updateFooter()
            let idx = self.session.selectedIndex
            self.tableView.reloadData()
            let count = self.numberOfRows(in: self.tableView)
            if expanded, count > 0, idx >= 0, idx < count {
                self.tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                self.tableView.scrollRowToVisible(idx)
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }

    // MARK: - Search

    public func controlTextDidChange(_ obj: Notification) {
        let text = searchField.stringValue
        aiAnswerView.clear() // a new query dismisses any shown answer
        quickActionsShown = false // typing supersedes the quick-action strip
        searchGeneration &+= 1
        let generation = searchGeneration
        searchDebounceWork?.cancel()

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loadEmptyResults(firstRun: false)
            footerError = nil
            applyLayout(animated: true)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.searchGeneration == generation else { return }
            self.searchQueue.async {
                do {
                    var list = try self.session.computeResults(for: text)
                    if list.isEmpty, let ai = self.aiIntegration {
                        list = ai.offers(for: text)
                    }
                    ResultIcon.preload(list)
                    DispatchQueue.main.async {
                        guard self.searchGeneration == generation else { return }
                        self.session.applyResults(text, list)
                        self.footerError = nil
                        self.applyLayout(animated: true)
                    }
                } catch {
                    let message = (error as? CoreError)?.message ?? error.localizedDescription
                    DispatchQueue.main.async {
                        guard self.searchGeneration == generation else { return }
                        self.footerError = message
                        self.applyLayout(animated: true)
                    }
                }
            }
        }
        searchDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(searchDebounceNs) / 1e9, execute: work)
    }

    private func loadEmptyResults(firstRun: Bool) {
        // Spotlight-bare empty state: no dumped list. Quick actions live in the
        // →-revealed chip strip; the starter catalog is retained for other callers.
        _ = firstRun
        session.applyResults("", [])
    }

    private func cancelPendingSearch() {
        searchGeneration &+= 1
        searchDebounceWork?.cancel()
        searchDebounceWork = nil
    }

    // MARK: - Table

    public func numberOfRows(in tableView: NSTableView) -> Int {
        session.objectMode ? session.objectActions.count : session.results.count
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LauncherTableRowView()
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        session.selectIndex(row)
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : panelWidth - 16
        let cell = tableView.makeView(
            withIdentifier: LauncherResultCellView.reuseIdentifier,
            owner: self
        ) as? LauncherResultCellView ?? LauncherResultCellView(
            frame: NSRect(x: 0, y: 0, width: width, height: 40)
        )
        cell.prepareForReuse()
        let iconView = cell.resultIconView
        let title = cell.titleLabel

        if session.objectMode, session.objectActions.indices.contains(row) {
            let action = session.objectActions[row]
            title.stringValue = action.title
            if action.isDestructive { title.textColor = Tokens.System.danger }
            iconView.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
            iconView.contentTintColor = Tokens.System.secondaryLabel
        } else if session.results.indices.contains(row) {
            let r = session.results[row]
            if r.kind == .emoji {
                iconView.isHidden = true
                title.stringValue = "\(r.title)  \(r.subtitle ?? "")"
                title.font = NSFont.systemFont(ofSize: 16)
                cell.updateFrames(width: width, emoji: true)
            } else {
                cell.updateFrames(width: width)
                iconView.image = ResultIcon.image(for: r)
                title.stringValue = r.title
            }
        }

        cell.setAccessibilityLabel(title.stringValue)
        return cell
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        refreshAppearance()
    }

    private func refreshAppearance() {
        rootView.effectiveAppearance.performAsCurrentDrawingAppearance {
            rootView.layer?.borderColor = Tokens.System.separator.withAlphaComponent(0.35).cgColor
            let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            rootView.layer?.backgroundColor = reduceTransparency
                ? Tokens.System.windowBackground.cgColor
                : NSColor.clear.cgColor
            effectView?.isHidden = reduceTransparency
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            searchFocusView.layer?.borderWidth = increaseContrast ? 3 : 2
            searchFocusView.layer?.borderColor = Tokens.System.accent.cgColor
            searchFocusView.layer?.backgroundColor = Tokens.System.accent
                .withAlphaComponent(increaseContrast ? 0.16 : 0.08)
                .cgColor
        }
    }

    // MARK: - Keys / actions

    @objc func confirmSelection() {
        let row = tableView.selectedRow
        if row >= 0 { session.selectIndex(row) }
        do {
            let confirmation = try session.prepareConfirmation()
            switch confirmation.actionName {
            case "ai.ask": runAI(confirmation); return
            case "web.search": runWebSearch(confirmation); return
            case "create.snippet", "create.quicklink": presentCreate(confirmation); return
            default: break
            }
            if confirmation.requiresUserConfirmation, !confirmDestructiveAction(confirmation) {
                return
            }
            hide()
            confirmationQueue.async { [weak self] in
                guard let self else { return }
                do {
                    _ = try self.session.execute(confirmation, actor: .user)
                } catch {
                    let message = (error as? CoreError)?.message ?? error.localizedDescription
                    DispatchQueue.main.async { [weak self] in
                        self?.showConfirmationFailure(message, query: confirmation.query)
                    }
                }
            }
        } catch {
            footerError = (error as? CoreError)?.message ?? error.localizedDescription
            applyLayout(animated: false)
        }
    }

    private func confirmDestructiveAction(_ confirmation: LauncherConfirmation) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = confirmation.actionName == "command.run"
            ? "Empty Trash?"
            : "Confirm Destructive Action"
        alert.informativeText = "This action cannot be undone from Summon."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showConfirmationFailure(_ message: String, query: String) {
        show()
        searchField.stringValue = query
        footerError = message
        applyLayout(animated: false)
    }

    private func refreshPermissionHint() {
        let snap = PermissionStatus.snapshot()
        permissionHint = snap.accessibilityTrusted ? nil : "Accessibility off"
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
        parts.append("v\(SummonVersion.string)")
        footerLabel.stringValue = parts.joined(separator: "  ·  ")
    }

}
