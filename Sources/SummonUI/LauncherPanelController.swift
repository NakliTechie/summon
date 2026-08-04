import AppKit
import Foundation
import SummonCore

/// AppKit launcher panel — native materials, semantic colors, HIG spacing.
/// Behavior: ↑↓↩ Tab/⌘K, permission banners, multi-display, staged strip.
public final class LauncherPanelController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public let session: LauncherSession
    public let panel: KeyablePanel
    private let searchField: NSSearchField
    private let tableView: NSTableView
    private let emptyLabel: NSTextField
    private let scrollView: NSScrollView
    private let footerLabel: NSTextField
    private let stagedLabel: NSTextField
    /// Transient search/invoke error (footer only — never a top red banner).
    private var footerError: String?
    private var permissionHint: String?
    private var resignHideWork: DispatchWorkItem?
    /// Suppress dismiss while we intentionally activate / focus the panel.
    private var suppressResignHide = false
    private let acceptButton: NSButton
    private let rejectButton: NSButton
    private let searchDivider: NSBox
    private let footerDivider: NSBox
    private var effectView: NSVisualEffectView?
    private let rootView: NSView
    private let panelWidth: CGFloat = 640
    private let panelHeight: CGFloat = 440
    private var stagedID: String?
    private var searchGeneration: UInt64 = 0
    private let searchQueue = DispatchQueue(label: "summon.launcher.search", qos: .userInitiated)
    private var searchDebounceWork: DispatchWorkItem?
    private let searchDebounceNs: UInt64 = 50_000_000

    // swiftlint:disable:next function_body_length
    public init(core: SummonCore) {
        self.session = LauncherSession(core: core)

        let rect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        // KeyablePanel: borderless still accepts key focus (required for search typing).
        panel = KeyablePanel(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        // Follow system light/dark automatically.
        panel.appearance = nil

        rootView = NSView(frame: rect)
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = Tokens.Metrics.panelCornerRadius
        if #available(macOS 11.0, *) {
            rootView.layer?.cornerCurve = .continuous
        }
        rootView.layer?.masksToBounds = true
        // Subtle system hairline edge (reads correctly in light + dark).
        rootView.layer?.borderWidth = 1
        rootView.layer?.borderColor = Tokens.System.separator.withAlphaComponent(0.45).cgColor
        panel.contentView = rootView

        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if reduceTransparency {
            rootView.layer?.backgroundColor = Tokens.System.windowBackground.cgColor
        } else {
            let effect = NSVisualEffectView(frame: rootView.bounds)
            effect.autoresizingMask = [.width, .height]
            // Popover material matches menus / Spotlight-adjacent chrome.
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            rootView.addSubview(effect, positioned: .below, relativeTo: nil)
            effectView = effect
        }

        let inset = Tokens.Metrics.contentInset

        // Native search field (cancel button, focus ring policy, placeholder styling).
        searchField = NSSearchField(
            frame: NSRect(x: inset, y: panelHeight - 56, width: panelWidth - inset * 2, height: 28)
        )
        searchField.placeholderString = "Search apps, files, clipboard…"
        searchField.font = Tokens.TypeScale.search
        searchField.focusRingType = .default
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.isEnabled = true
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.cancelButtonCell?.isTransparent = false
        }
        rootView.addSubview(searchField)

        searchDivider = Self.makeHairline(
            frame: NSRect(x: 0, y: panelHeight - 68, width: panelWidth, height: 1)
        )
        rootView.addSubview(searchDivider)

        stagedLabel = NSTextField(wrappingLabelWithString: "")
        stagedLabel.frame = NSRect(x: inset, y: panelHeight - 108, width: panelWidth - 150, height: 32)
        stagedLabel.font = Tokens.TypeScale.caption
        stagedLabel.textColor = Tokens.System.staged
        stagedLabel.isHidden = true
        rootView.addSubview(stagedLabel)

        acceptButton = NSButton(title: "Accept", target: nil, action: nil)
        acceptButton.bezelStyle = .rounded
        acceptButton.controlSize = .small
        acceptButton.frame = NSRect(x: panelWidth - 118, y: panelHeight - 104, width: 54, height: 24)
        acceptButton.isHidden = true
        rootView.addSubview(acceptButton)

        rejectButton = NSButton(title: "Reject", target: nil, action: nil)
        rejectButton.bezelStyle = .rounded
        rejectButton.controlSize = .small
        rejectButton.frame = NSRect(x: panelWidth - 60, y: panelHeight - 104, width: 48, height: 24)
        rejectButton.isHidden = true
        rootView.addSubview(rejectButton)

        // Results sit below the search divider (y = panelHeight - 68), above the footer (y = 32).
        let resultsTopY = panelHeight - 68
        let resultsBottomY: CGFloat = 32
        scrollView = NSScrollView(
            frame: NSRect(
                x: 4,
                y: resultsBottomY,
                width: panelWidth - 8,
                height: max(80, resultsTopY - resultsBottomY)
            )
        )
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        tableView = NSTableView(frame: scrollView.bounds)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = Tokens.Metrics.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        if #available(macOS 11.0, *) {
            tableView.style = .inset
        }
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.setAccessibilityElement(true)
        tableView.setAccessibilityRole(.list)
        tableView.setAccessibilityLabel("Search results")
        tableView.setAccessibilityEnabled(true)
        searchField.setAccessibilityLabel("Search")
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.width = panelWidth - 24
        tableView.addTableColumn(col)
        scrollView.documentView = tableView
        rootView.addSubview(scrollView)

        emptyLabel = NSTextField(labelWithString: "Type to search")
        emptyLabel.textColor = Tokens.System.secondaryLabel
        emptyLabel.font = Tokens.TypeScale.rowTitle
        emptyLabel.alignment = .center
        emptyLabel.frame = NSRect(x: inset, y: panelHeight / 2 - 10, width: panelWidth - inset * 2, height: 20)
        rootView.addSubview(emptyLabel)

        footerDivider = Self.makeHairline(
            frame: NSRect(x: 0, y: 28, width: panelWidth, height: 1)
        )
        rootView.addSubview(footerDivider)

        footerLabel = NSTextField(labelWithString: "↑↓  ·  ↩ Open  ·  Tab Actions  ·  Esc")
        footerLabel.frame = NSRect(x: inset, y: 8, width: panelWidth - inset * 2, height: 14)
        footerLabel.font = Tokens.TypeScale.footnote
        footerLabel.textColor = Tokens.System.tertiaryLabel
        footerLabel.alignment = .center
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

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )

        refreshPermissionHint()
        applyChromeForAppearance()
        reloadUI()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private static func makeHairline(frame: NSRect) -> NSBox {
        let box = NSBox(frame: frame)
        box.boxType = .separator
        box.autoresizingMask = [.width]
        return box
    }

    @objc private func appearanceChanged() {
        applyChromeForAppearance()
    }

    private func applyChromeForAppearance() {
        rootView.layer?.borderColor = Tokens.System.separator.withAlphaComponent(0.45).cgColor
        if effectView == nil {
            rootView.layer?.backgroundColor = Tokens.System.windowBackground.cgColor
        }
        // Re-resolve label colors when appearance flips.
        searchField.textColor = Tokens.System.label
        emptyLabel.textColor = Tokens.System.secondaryLabel
        footerLabel.textColor = Tokens.System.tertiaryLabel
        stagedLabel.textColor = Tokens.System.staged
        tableView.reloadData()
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        session.selectIndex(row)
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LauncherTableRowView()
    }

    @objc private func confirmSelection() {
        let row = tableView.selectedRow
        if row >= 0 {
            session.selectIndex(row)
        }
        do {
            _ = try session.confirm(actor: .user)
            showError(nil)
            hide()
        } catch {
            showError((error as? CoreError)?.message ?? error.localizedDescription)
        }
    }

    public func show() {
        applyChromeForAppearance()
        positionOnActiveScreen()
        refreshPermissionHint()
        refreshStagedStrip()
        layoutResultsArea(stagedVisible: !acceptButton.isHidden)
        // UI-1: blank until the user types (Spotlight-like).
        if searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.applyResults("", [])
            reloadUI()
        }
        suppressResignHide = true
        resignHideWork?.cancel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Defer focus: layout + activation must finish before first responder sticks.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.makeKey()
            _ = self.panel.makeFirstResponder(self.searchField)
            self.searchField.currentEditor()?.selectedRange = NSRange(
                location: self.searchField.stringValue.utf16.count,
                length: 0
            )
            self.suppressResignHide = false
        }
    }

    public func hide() {
        resignHideWork?.cancel()
        panel.orderOut(nil)
    }

    /// UI-2: Spotlight-like dismiss when focus leaves the panel.
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

    public func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else {
            panel.center()
            return
        }
        let vis = screen.visibleFrame
        let x = vis.midX - panelWidth / 2
        // Slightly above center — Spotlight-like.
        let y = vis.midY - panelHeight / 2 + 48
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Discreet footer hint only — never a top red alert.
    private func refreshPermissionHint() {
        let snap = PermissionStatus.snapshot()
        if !snap.accessibilityTrusted {
            permissionHint = "Accessibility off · Settings › Privacy"
        } else {
            permissionHint = nil
        }
        updateFooter()
    }

    private func refreshStagedStrip() {
        do {
            let list = try session.core.staged.list(state: "staged")
            if let first = list.first {
                stagedID = first.id
                let preview = first.output.prefix(120)
                stagedLabel.stringValue = "Staged (\(first.rung)): \(preview)"
                stagedLabel.isHidden = false
                acceptButton.isHidden = false
                rejectButton.isHidden = false
                layoutResultsArea(stagedVisible: true)
            } else {
                stagedID = nil
                stagedLabel.isHidden = true
                acceptButton.isHidden = true
                rejectButton.isHidden = true
                layoutResultsArea(stagedVisible: false)
            }
        } catch {
            stagedID = nil
            stagedLabel.isHidden = true
            acceptButton.isHidden = true
            rejectButton.isHidden = true
            layoutResultsArea(stagedVisible: false)
        }
    }

    private func layoutResultsArea(stagedVisible: Bool) {
        // AppKit y grows up. Keep results strictly below search chrome so the
        // scroll view never covers the search field (that blocked typing/clicks).
        let footerTop: CGFloat = 32
        let searchChromeBottom = panelHeight - 68 // search divider
        let topLimit = stagedVisible ? (panelHeight - 116) : searchChromeBottom
        let height = max(80, topLimit - footerTop)
        scrollView.frame = NSRect(x: 4, y: footerTop, width: panelWidth - 8, height: height)
    }

    @objc private func acceptStaged() {
        guard let id = stagedID else { return }
        guard let p = try? session.core.staged.get(id), p.state == "staged" else {
            refreshStagedStrip()
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
    }

    @objc private func rejectStaged() {
        guard let id = stagedID else { return }
        if let p = try? session.core.staged.get(id), p.rung == "agent" {
            try? session.core.rejectStagedAgentAction(id: id)
        } else {
            try? session.core.staged.setState(id: id, state: "rejected")
        }
        refreshStagedStrip()
    }

    public func controlTextDidChange(_ obj: Notification) {
        let text = searchField.stringValue
        searchGeneration &+= 1
        let generation = searchGeneration
        searchDebounceWork?.cancel()
        // UI-1: no results until there is a non-empty query.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.applyResults("", [])
            showError(nil)
            reloadUI()
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
                        self.showError(nil)
                        self.reloadUI()
                    }
                } catch {
                    let message = (error as? CoreError)?.message ?? error.localizedDescription
                    DispatchQueue.main.async {
                        guard self.searchGeneration == generation else { return }
                        self.showError(message)
                    }
                }
            }
        }
        searchDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(searchDebounceNs) / 1_000_000_000, execute: work)
    }

    private func showError(_ message: String?) {
        footerError = (message?.isEmpty == false) ? message : nil
        updateFooter()
    }

    private func updateFooter() {
        let nav: String
        if session.objectMode {
            nav = "↩ Run  ·  Esc Back"
        } else {
            nav = "↑↓  ·  ↩ Open  ·  Tab Actions  ·  Esc"
        }
        if let err = footerError, !err.isEmpty {
            footerLabel.stringValue = "\(nav)  ·  \(err)"
            footerLabel.textColor = Tokens.System.secondaryLabel
        } else if let hint = permissionHint, !hint.isEmpty {
            footerLabel.stringValue = "\(nav)  ·  \(hint)"
            footerLabel.textColor = Tokens.System.tertiaryLabel
        } else {
            footerLabel.stringValue = nav
            footerLabel.textColor = Tokens.System.tertiaryLabel
        }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if session.objectMode {
            return session.objectActions.count
        }
        return session.results.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : panelWidth - 24
        let rowH = Tokens.Metrics.rowHeight
        let icon = Tokens.Metrics.iconSize
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: width, height: rowH))

        let iconView = NSImageView(frame: NSRect(x: 10, y: (rowH - icon) / 2, width: icon, height: icon))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        if #available(macOS 11.0, *) {
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        }

        let textLeft: CGFloat = 10 + icon + 10
        let textWidth = max(40, width - textLeft - 12)

        let titleField = NSTextField(labelWithString: "")
        titleField.frame = NSRect(x: textLeft, y: 22, width: textWidth, height: 17)
        titleField.font = Tokens.TypeScale.rowTitle
        titleField.textColor = Tokens.System.label
        titleField.lineBreakMode = .byTruncatingTail
        titleField.drawsBackground = false

        let subtitleField = NSTextField(labelWithString: "")
        subtitleField.frame = NSRect(x: textLeft, y: 6, width: textWidth, height: 14)
        subtitleField.font = Tokens.TypeScale.rowSubtitle
        subtitleField.textColor = Tokens.System.secondaryLabel
        subtitleField.lineBreakMode = .byTruncatingMiddle
        subtitleField.drawsBackground = false

        if session.objectMode, session.objectActions.indices.contains(row) {
            let action = session.objectActions[row]
            titleField.stringValue = action.title
            if action.isDestructive {
                titleField.textColor = Tokens.System.danger
                subtitleField.stringValue = "Destructive"
            } else {
                subtitleField.stringValue = "Action"
            }
            iconView.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "action")
            iconView.contentTintColor = Tokens.System.secondaryLabel
        } else if session.results.indices.contains(row) {
            let r = session.results[row]
            let star = row == 0 && r.score >= 0.9 ? "★ " : ""
            if r.kind == .emoji {
                iconView.isHidden = true
                titleField.stringValue = "\(star)\(r.title)  \(r.subtitle ?? "")"
                titleField.font = Tokens.TypeScale.search
                titleField.frame = NSRect(x: 14, y: (rowH - 20) / 2, width: max(40, width - 28), height: 20)
                subtitleField.isHidden = true
            } else {
                iconView.image = ResultIcon.image(for: r)
                titleField.stringValue = "\(star)\(r.title)"
                if r.kind == .app {
                    subtitleField.stringValue = "Application"
                } else if let sub = r.subtitle, !sub.isEmpty {
                    subtitleField.stringValue = sub
                } else {
                    subtitleField.stringValue = r.kind.rawValue.capitalized
                }
            }
        }

        let a11y = titleField.stringValue
            + (subtitleField.isHidden || subtitleField.stringValue.isEmpty
                ? ""
                : ", \(subtitleField.stringValue)")
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.row)
        cell.setAccessibilityLabel(a11y)
        cell.setAccessibilityIndex(row)
        cell.addSubview(iconView)
        cell.addSubview(titleField)
        cell.addSubview(subtitleField)
        cell.imageView = iconView
        cell.textField = titleField
        return cell
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible, panel.isKeyWindow || NSApp.keyWindow === panel else {
            return event
        }

        // Let the search field handle normal typing / editing keys.
        // Only intercept navigation and launcher chords.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "k" {
            if session.objectMode {
                session.exitObjectMode()
            } else {
                session.enterObjectMode()
            }
            reloadUI()
            return nil
        }

        switch event.keyCode {
        case 125: // down
            session.moveSelection(by: 1)
            reloadUI()
            return nil
        case 126: // up
            session.moveSelection(by: -1)
            reloadUI()
            return nil
        case 36: // return
            confirmSelection()
            return nil
        case 48: // tab
            if session.objectMode {
                session.exitObjectMode()
            } else {
                session.enterObjectMode()
            }
            reloadUI()
            return nil
        case 53: // escape
            if session.objectMode {
                session.exitObjectMode()
                reloadUI()
            } else if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            } else {
                hide()
            }
            return nil
        default:
            // Ensure typing lands in the search field if focus was stolen.
            let editingSearch = panel.firstResponder === searchField
                || panel.firstResponder === searchField.currentEditor()
            if !editingSearch {
                let chars = event.charactersIgnoringModifiers ?? ""
                let isPrintable = chars.contains {
                    $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " "
                }
                if isPrintable {
                    _ = panel.makeFirstResponder(searchField)
                }
            }
            return event
        }
    }

    private func reloadUI() {
        let emptyQuery = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if emptyQuery {
            // Spotlight-like: no empty-state lecture, just chrome + caret.
            emptyLabel.isHidden = true
        } else if session.results.isEmpty && !session.objectMode {
            emptyLabel.stringValue = "No Results"
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
        updateFooter()
        tableView.reloadData()
        let idx = session.selectedIndex
        if !emptyQuery, idx >= 0, numberOfRows(in: tableView) > idx {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        }
    }
}
