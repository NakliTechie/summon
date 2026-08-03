import AppKit
import Foundation
import SummonCore

/// AppKit launcher panel — search field + results + footer + banners + staged strip.
/// Aligns toward UX reference: glass, ↑↓↩ Tab/⌘K, permission banners, multi-display.
public final class LauncherPanelController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public let session: LauncherSession
    public let panel: NSPanel
    private let searchField: NSTextField
    private let tableView: NSTableView
    private let emptyLabel: NSTextField
    private let scrollView: NSScrollView
    private let footerLabel: NSTextField
    private let bannerLabel: NSTextField
    private let stagedLabel: NSTextField
    private let acceptButton: NSButton
    private let rejectButton: NSButton
    private var effectView: NSVisualEffectView?
    private let panelWidth: CGFloat = 640
    private let panelHeight: CGFloat = 440
    private var stagedID: String?

    // swiftlint:disable:next function_body_length
    public init(core: SummonCore) {
        self.session = LauncherSession(core: core)

        let rect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        panel = NSPanel(
            contentRect: rect,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: rect)
        panel.contentView = content

        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if reduceTransparency {
            content.wantsLayer = true
            content.layer?.backgroundColor = Tokens.Color.bgGlass.nsColor.cgColor
            content.layer?.cornerRadius = 12
        } else {
            let effect = NSVisualEffectView(frame: content.bounds)
            effect.autoresizingMask = [.width, .height]
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            content.addSubview(effect)
            effectView = effect
        }

        bannerLabel = NSTextField(labelWithString: "")
        bannerLabel.frame = NSRect(x: 16, y: panelHeight - 28, width: panelWidth - 32, height: 16)
        bannerLabel.font = NSFont.systemFont(ofSize: 11)
        bannerLabel.textColor = Tokens.Color.danger.nsColor
        bannerLabel.isHidden = true
        content.addSubview(bannerLabel)

        searchField = NSTextField(frame: NSRect(x: 16, y: panelHeight - 56, width: panelWidth - 32, height: 28))
        searchField.placeholderString = "Search apps, files, clipboard…  ·  ? for help"
        searchField.font = NSFont.systemFont(ofSize: 16)
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.backgroundColor = .clear
        searchField.textColor = Tokens.Color.text.nsColor
        content.addSubview(searchField)

        stagedLabel = NSTextField(wrappingLabelWithString: "")
        stagedLabel.frame = NSRect(x: 16, y: panelHeight - 100, width: panelWidth - 140, height: 36)
        stagedLabel.font = NSFont.systemFont(ofSize: 11)
        stagedLabel.textColor = Tokens.Color.staged.nsColor
        stagedLabel.isHidden = true
        content.addSubview(stagedLabel)

        acceptButton = NSButton(title: "Accept", target: nil, action: nil)
        acceptButton.bezelStyle = .rounded
        acceptButton.frame = NSRect(x: panelWidth - 120, y: panelHeight - 96, width: 52, height: 24)
        acceptButton.isHidden = true
        content.addSubview(acceptButton)

        rejectButton = NSButton(title: "Reject", target: nil, action: nil)
        rejectButton.bezelStyle = .rounded
        rejectButton.frame = NSRect(x: panelWidth - 64, y: panelHeight - 96, width: 48, height: 24)
        rejectButton.isHidden = true
        content.addSubview(rejectButton)

        scrollView = NSScrollView(frame: NSRect(x: 8, y: 28, width: panelWidth - 16, height: panelHeight - 120))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView = NSTableView(frame: scrollView.bounds)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 36
        tableView.style = .plain
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.width = panelWidth - 32
        tableView.addTableColumn(col)
        scrollView.documentView = tableView
        content.addSubview(scrollView)

        emptyLabel = NSTextField(labelWithString: "Type to search — apps, files, clipboard, snippets")
        emptyLabel.textColor = Tokens.Color.textDim.nsColor
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.alignment = .center
        emptyLabel.frame = NSRect(x: 16, y: panelHeight / 2 - 10, width: panelWidth - 32, height: 20)
        content.addSubview(emptyLabel)

        footerLabel = NSTextField(labelWithString: "↑↓ navigate  ·  ↩ run  ·  Tab/⌘K actions  ·  Esc close")
        footerLabel.frame = NSRect(x: 16, y: 6, width: panelWidth - 32, height: 16)
        footerLabel.font = NSFont.systemFont(ofSize: 10)
        footerLabel.textColor = Tokens.Color.textDim.nsColor
        content.addSubview(footerLabel)

        super.init()

        searchField.delegate = self
        tableView.dataSource = self
        tableView.delegate = self
        acceptButton.target = self
        acceptButton.action = #selector(acceptStaged)
        rejectButton.target = self
        rejectButton.action = #selector(rejectStaged)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }

        refreshPermissionBanner()
        reloadUI()
    }

    public func show() {
        positionOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        NSApp.activate(ignoringOtherApps: true)
        refreshPermissionBanner()
        refreshStagedStrip()
        // Empty query shows recents/favorites
        if searchField.stringValue.isEmpty {
            _ = try? session.setQuery("")
            reloadUI()
        }
    }

    public func hide() {
        panel.orderOut(nil)
    }

    public func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    /// RC-57: center on the screen containing the mouse (active display).
    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else {
            panel.center()
            return
        }
        let vis = screen.visibleFrame
        let x = vis.midX - panelWidth / 2
        let y = vis.midY - panelHeight / 2 + 40
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func refreshPermissionBanner() {
        let snap = PermissionStatus.snapshot()
        let msgs = snap.bannerMessages
        if msgs.isEmpty {
            bannerLabel.isHidden = true
            bannerLabel.stringValue = ""
        } else {
            bannerLabel.stringValue = msgs[0]
            bannerLabel.isHidden = false
        }
    }

    private func refreshStagedStrip() {
        do {
            let list = try session.core.staged.list(state: "staged")
            if let first = list.first {
                stagedID = first.id
                let preview = first.output.prefix(120)
                stagedLabel.stringValue = "AI staged (\(first.rung)): \(preview)"
                stagedLabel.isHidden = false
                acceptButton.isHidden = false
                rejectButton.isHidden = false
            } else {
                stagedID = nil
                stagedLabel.isHidden = true
                acceptButton.isHidden = true
                rejectButton.isHidden = true
            }
        } catch {
            stagedID = nil
            stagedLabel.isHidden = true
            acceptButton.isHidden = true
            rejectButton.isHidden = true
        }
    }

    @objc private func acceptStaged() {
        guard let id = stagedID else { return }
        try? session.core.staged.setState(id: id, state: "accepted")
        if let p = try? session.core.staged.get(id) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(p.output, forType: .string)
        }
        refreshStagedStrip()
    }

    @objc private func rejectStaged() {
        guard let id = stagedID else { return }
        try? session.core.staged.setState(id: id, state: "rejected")
        refreshStagedStrip()
    }

    // MARK: - NSTextFieldDelegate

    public func controlTextDidChange(_ obj: Notification) {
        let text = searchField.stringValue
        do {
            _ = try session.setQuery(text)
            reloadUI()
        } catch {
            // Keep last good results
        }
    }

    // MARK: - Table

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if session.objectMode {
            return session.objectActions.count
        }
        return session.results.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 600, height: 36))
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 8, y: 8, width: 580, height: 20)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = Tokens.Color.text.nsColor
        if session.objectMode, session.objectActions.indices.contains(row) {
            let action = session.objectActions[row]
            label.stringValue = action.isDestructive ? "\(action.title)  · destructive" : action.title
            if action.isDestructive {
                label.textColor = Tokens.Color.danger.nsColor
            }
        } else if session.results.indices.contains(row) {
            let r = session.results[row]
            let sub = r.subtitle.map { "  ·  \($0)" } ?? ""
            let star = row == 0 && r.score >= 0.9 ? "★ " : ""
            label.stringValue = "\(star)[\(r.kind.rawValue)] \(r.title)\(sub)"
        }
        // a11y
        cell.setAccessibilityRole(.row)
        cell.setAccessibilityLabel(label.stringValue)
        cell.addSubview(label)
        return cell
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard panel.isKeyWindow || panel.isVisible else { return event }

        // ⌘K → object mode (RC-44)
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
            do {
                _ = try session.confirm(actor: .user)
                hide()
            } catch {
                // stay open
            }
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
            } else {
                hide()
            }
            return nil
        default:
            return event
        }
    }

    private func reloadUI() {
        if searchField.stringValue.isEmpty && session.results.isEmpty {
            emptyLabel.stringValue = "Type to search — or open recents with empty query"
            emptyLabel.isHidden = false
        } else if session.results.isEmpty && !session.objectMode {
            emptyLabel.stringValue = "No results — try clip …, kind:pdf, or ?"
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
        if session.objectMode {
            footerLabel.stringValue = "Object actions  ·  ↩ run  ·  Esc back"
        } else {
            footerLabel.stringValue = "↑↓ navigate  ·  ↩ run  ·  Tab/⌘K actions  ·  Esc close"
        }
        tableView.reloadData()
        let idx = session.selectedIndex
        if idx >= 0, numberOfRows(in: tableView) > idx {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        }
    }
}
