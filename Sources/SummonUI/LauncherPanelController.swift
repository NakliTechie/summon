import AppKit
import Foundation
import SummonCore

/// Spotlight-style launcher: compact search bar until the user types, then expands for results.
public final class LauncherPanelController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public let session: LauncherSession
    public let panel: KeyablePanel

    private let rootView: NSView
    private var effectView: NSVisualEffectView?
    /// Leading magnifying glass (separate from the text field so they never overlap).
    private let searchIconView: NSImageView
    private let searchField: NSTextField
    private let searchDivider: NSBox
    private let scrollView: NSScrollView
    private let tableView: NSTableView
    private let emptyLabel: NSTextField
    private let stagedLabel: NSTextField
    private let acceptButton: NSButton
    private let rejectButton: NSButton
    private let footerLabel: NSTextField

    private let panelWidth: CGFloat = 680
    /// Spotlight-like single-line bar.
    private let collapsedHeight: CGFloat = 48
    private let searchBandHeight: CGFloat = 48
    private let maxResultsHeight: CGFloat = 380
    private let footerHeight: CGFloat = 22
    private let stagedBandHeight: CGFloat = 36

    private var stagedID: String?
    private var footerError: String?
    private var permissionHint: String?
    private var resignHideWork: DispatchWorkItem?
    private var suppressResignHide = false
    private var searchGeneration: UInt64 = 0
    private let searchQueue = DispatchQueue(label: "summon.launcher.search", qos: .userInitiated)
    private var searchDebounceWork: DispatchWorkItem?
    private let searchDebounceNs: UInt64 = 40_000_000

    public init(core: SummonCore) {
        self.session = LauncherSession(core: core)

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

        rootView = NSView(frame: rect)
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = 12
        if #available(macOS 11.0, *) {
            rootView.layer?.cornerCurve = .continuous
        }
        rootView.layer?.masksToBounds = true
        rootView.layer?.borderWidth = 0.5
        rootView.layer?.borderColor = Tokens.System.separator.withAlphaComponent(0.35).cgColor
        panel.contentView = rootView

        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            rootView.layer?.backgroundColor = Tokens.System.windowBackground.cgColor
        } else {
            let effect = NSVisualEffectView(frame: rootView.bounds)
            effect.autoresizingMask = [.width, .height]
            // Closest stock material to Spotlight chrome.
            effect.material = .headerView
            effect.blendingMode = .behindWindow
            effect.state = .active
            rootView.addSubview(effect, positioned: .below, relativeTo: nil)
            effectView = effect
        }

        // Icon + plain text field (NSSearchField borderless stacks glyph on text).
        searchIconView = NSImageView(frame: .zero)
        searchIconView.imageScaling = .scaleProportionallyUpOrDown
        searchIconView.contentTintColor = Tokens.System.secondaryLabel
        if let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            searchIconView.image = img.withSymbolConfiguration(cfg)
        }
        rootView.addSubview(searchIconView)

        searchField = NSTextField(frame: .zero)
        searchField.font = NSFont.systemFont(ofSize: 20, weight: .regular)
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.backgroundColor = .clear
        searchField.textColor = Tokens.System.label
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Summon…",
            attributes: [
                .foregroundColor: Tokens.System.secondaryLabel,
                .font: NSFont.systemFont(ofSize: 20, weight: .regular),
            ]
        )
        searchField.setAccessibilityLabel("Search")
        rootView.addSubview(searchField)

        searchDivider = NSBox(frame: .zero)
        searchDivider.boxType = .separator
        searchDivider.isHidden = true
        rootView.addSubview(searchDivider)

        stagedLabel = NSTextField(wrappingLabelWithString: "")
        stagedLabel.font = Tokens.TypeScale.caption
        stagedLabel.textColor = Tokens.System.staged
        stagedLabel.isHidden = true
        rootView.addSubview(stagedLabel)

        acceptButton = NSButton(title: "Accept", target: nil, action: nil)
        acceptButton.bezelStyle = .rounded
        acceptButton.controlSize = .small
        acceptButton.isHidden = true
        rootView.addSubview(acceptButton)

        rejectButton = NSButton(title: "Reject", target: nil, action: nil)
        rejectButton.bezelStyle = .rounded
        rejectButton.controlSize = .small
        rejectButton.isHidden = true
        rootView.addSubview(rejectButton)

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

        searchField.delegate = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(confirmSelection)
        tableView.target = self
        acceptButton.target = self
        acceptButton.action = #selector(acceptStaged)
        rejectButton.target = self
        rejectButton.action = #selector(rejectStaged)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] in
            self?.handleKey($0) ?? $0
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )

        refreshPermissionHint()
        applyLayout(animated: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Show / hide

    public func show() {
        searchField.stringValue = ""
        session.applyResults("", [])
        footerError = nil
        refreshPermissionHint()
        refreshStagedStrip()
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
            self.suppressResignHide = false
        }
    }

    public func hide() {
        resignHideWork?.cancel()
        searchField.stringValue = ""
        session.applyResults("", [])
        panel.orderOut(nil)
    }

    public func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    @objc private func windowDidResignKey(_ note: Notification) {
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

    private var hasQuery: Bool {
        !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showResultsChrome: Bool {
        hasQuery || !acceptButton.isHidden
    }

    private func targetHeight() -> CGFloat {
        var h = searchBandHeight
        if !acceptButton.isHidden {
            h += stagedBandHeight
        }
        if hasQuery {
            let rows = CGFloat(max(session.results.count, session.objectMode ? session.objectActions.count : 0))
            if rows == 0 {
                h += 56 // "No Results" strip
            } else {
                let listH = min(maxResultsHeight, rows * tableView.rowHeight + 8)
                h += listH
            }
            h += footerHeight
        }
        return max(collapsedHeight, h)
    }

    private func applyLayout(animated: Bool) {
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

            let inset: CGFloat = 14
            let iconSize: CGFloat = 18
            let bandY = height - self.searchBandHeight
            // Magnifying glass left; text field starts after a clear gap.
            self.searchIconView.frame = NSRect(
                x: inset,
                y: bandY + (self.searchBandHeight - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            let textX = inset + iconSize + 10
            self.searchField.frame = NSRect(
                x: textX,
                y: bandY + 8,
                width: self.panelWidth - textX - inset,
                height: 32
            )

            let dividerY = height - self.searchBandHeight
            self.searchDivider.frame = NSRect(x: 0, y: dividerY, width: self.panelWidth, height: 1)
            self.searchDivider.isHidden = !expanded

            var contentTop = dividerY
            if !self.acceptButton.isHidden {
                contentTop -= self.stagedBandHeight
                self.stagedLabel.frame = NSRect(
                    x: inset,
                    y: contentTop + 6,
                    width: self.panelWidth - 140,
                    height: 24
                )
                self.acceptButton.frame = NSRect(
                    x: self.panelWidth - 118,
                    y: contentTop + 6,
                    width: 52,
                    height: 22
                )
                self.rejectButton.frame = NSRect(
                    x: self.panelWidth - 62,
                    y: contentTop + 6,
                    width: 48,
                    height: 22
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
            self.tableView.reloadData()
            let idx = self.session.selectedIndex
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
        searchGeneration &+= 1
        let generation = searchGeneration
        searchDebounceWork?.cancel()

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.applyResults("", [])
            footerError = nil
            applyLayout(animated: true)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.searchQueue.async {
                guard self.searchGeneration == generation else { return }
                do {
                    let list = try self.session.computeResults(for: text)
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
        let rowH: CGFloat = 40
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: width, height: rowH))

        let iconView = NSImageView(frame: NSRect(x: 12, y: 6, width: 28, height: 28))
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: "")
        title.frame = NSRect(x: 48, y: 11, width: max(40, width - 60), height: 18)
        title.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        title.textColor = Tokens.System.label
        title.lineBreakMode = .byTruncatingTail
        title.drawsBackground = false

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
                title.frame = NSRect(x: 14, y: 10, width: max(40, width - 28), height: 20)
            } else {
                iconView.image = ResultIcon.image(for: r)
                title.stringValue = r.title
            }
        }

        cell.addSubview(iconView)
        cell.addSubview(title)
        cell.imageView = iconView
        cell.textField = title
        cell.setAccessibilityLabel(title.stringValue)
        return cell
    }

    // MARK: - Keys / actions

    @objc private func confirmSelection() {
        let row = tableView.selectedRow
        if row >= 0 { session.selectIndex(row) }
        do {
            _ = try session.confirm(actor: .user)
            hide()
        } catch {
            footerError = (error as? CoreError)?.message ?? error.localizedDescription
            applyLayout(animated: false)
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible, panel.isKeyWindow || NSApp.keyWindow === panel else {
            return event
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
            if hasQuery { confirmSelection() }
            return nil
        case 48:
            if session.objectMode { session.exitObjectMode() } else { session.enterObjectMode() }
            applyLayout(animated: false)
            return nil
        case 53:
            if session.objectMode {
                session.exitObjectMode()
                applyLayout(animated: false)
            } else if hasQuery {
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

    private func refreshPermissionHint() {
        let snap = PermissionStatus.snapshot()
        permissionHint = snap.accessibilityTrusted ? nil : "Accessibility off"
        updateFooter()
    }

    private func updateFooter() {
        guard showResultsChrome else {
            footerLabel.stringValue = ""
            return
        }
        var parts = ["↩ Open"]
        if session.objectMode { parts = ["↩ Run", "Esc Back"] }
        if let err = footerError, !err.isEmpty { parts.append(err) }
        else if let hint = permissionHint { parts.append(hint) }
        footerLabel.stringValue = parts.joined(separator: "  ·  ")
    }

    private func refreshStagedStrip() {
        do {
            let list = try session.core.staged.list(state: "staged")
            if let first = list.first {
                stagedID = first.id
                stagedLabel.stringValue = "Staged (\(first.rung)): \(first.output.prefix(80))"
                stagedLabel.isHidden = false
                acceptButton.isHidden = false
                rejectButton.isHidden = false
            } else {
                clearStagedChrome()
            }
        } catch {
            clearStagedChrome()
        }
    }

    private func clearStagedChrome() {
        stagedID = nil
        stagedLabel.isHidden = true
        acceptButton.isHidden = true
        rejectButton.isHidden = true
    }

    @objc private func acceptStaged() {
        guard let id = stagedID else { return }
        guard let p = try? session.core.staged.get(id), p.state == "staged" else {
            refreshStagedStrip()
            applyLayout(animated: true)
            return
        }
        if p.rung == "agent" {
            _ = try? session.core.acceptStagedAgentAction(id: id)
        } else {
            try? session.core.staged.setState(id: id, state: "accepted")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(p.output, forType: .string)
        }
        refreshStagedStrip()
        applyLayout(animated: true)
    }

    @objc private func rejectStaged() {
        guard let id = stagedID else { return }
        if let p = try? session.core.staged.get(id), p.rung == "agent" {
            try? session.core.rejectStagedAgentAction(id: id)
        } else {
            try? session.core.staged.setState(id: id, state: "rejected")
        }
        refreshStagedStrip()
        applyLayout(animated: true)
    }
}
