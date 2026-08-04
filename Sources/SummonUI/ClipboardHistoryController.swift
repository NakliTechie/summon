import AppKit
import Foundation
import SummonCore

/// Dedicated clipboard history browser (CB-3 / Maccy-class surface).
/// Capture is process-lifetime (`PasteboardService`); this panel only browses/acts.
public final class ClipboardHistoryController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public let panel: KeyablePanel
    private let core: SummonCore
    private let searchField: NSSearchField
    private let tableView: NSTableView
    private let scrollView: NSScrollView
    private let emptyLabel: NSTextField
    private let footerLabel: NSTextField
    private let rootView: NSView
    private var effectView: NSVisualEffectView?
    private let panelWidth: CGFloat = 420
    private let panelHeight: CGFloat = 480
    private var items: [ClipboardItem] = []
    private var selectedIndex: Int = 0
    private var resignHideWork: DispatchWorkItem?
    private var suppressResignHide = false

    public init(core: SummonCore) {
        self.core = core
        let rect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
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

        rootView = NSView(frame: rect)
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = Tokens.Metrics.panelCornerRadius
        if #available(macOS 11.0, *) {
            rootView.layer?.cornerCurve = .continuous
        }
        rootView.layer?.masksToBounds = true
        rootView.layer?.borderWidth = 1
        rootView.layer?.borderColor = Tokens.System.separator.withAlphaComponent(0.45).cgColor
        panel.contentView = rootView

        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            rootView.layer?.backgroundColor = Tokens.System.windowBackground.cgColor
        } else {
            let effect = NSVisualEffectView(frame: rootView.bounds)
            effect.autoresizingMask = [.width, .height]
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            rootView.addSubview(effect, positioned: .below, relativeTo: nil)
            effectView = effect
        }

        let inset = Tokens.Metrics.contentInset
        let title = NSTextField(labelWithString: "Clipboard")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Tokens.System.secondaryLabel
        title.frame = NSRect(x: inset, y: panelHeight - 28, width: 200, height: 16)
        rootView.addSubview(title)

        searchField = NSSearchField(
            frame: NSRect(x: inset, y: panelHeight - 58, width: panelWidth - inset * 2, height: 28)
        )
        searchField.placeholderString = "Filter history"
        searchField.font = Tokens.TypeScale.search
        searchField.isEditable = true
        searchField.isSelectable = true
        rootView.addSubview(searchField)

        let divider = NSBox(frame: NSRect(x: 0, y: panelHeight - 70, width: panelWidth, height: 1))
        divider.boxType = .separator
        rootView.addSubview(divider)

        scrollView = NSScrollView(
            frame: NSRect(x: 4, y: 32, width: panelWidth - 8, height: panelHeight - 70 - 32)
        )
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay

        tableView = NSTableView(frame: scrollView.bounds)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = Tokens.Metrics.rowHeight
        tableView.selectionHighlightStyle = .regular
        if #available(macOS 11.0, *) {
            tableView.style = .inset
        }
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.width = panelWidth - 24
        tableView.addTableColumn(col)
        scrollView.documentView = tableView
        rootView.addSubview(scrollView)

        emptyLabel = NSTextField(labelWithString: "No clipboard history yet")
        emptyLabel.font = Tokens.TypeScale.rowTitle
        emptyLabel.textColor = Tokens.System.secondaryLabel
        emptyLabel.alignment = .center
        emptyLabel.frame = NSRect(x: inset, y: panelHeight / 2 - 10, width: panelWidth - inset * 2, height: 20)
        rootView.addSubview(emptyLabel)

        footerLabel = NSTextField(
            labelWithString: "↩ Copy  ·  ⌘⌫ Delete  ·  ⌘P Pin  ·  ⌥⇧V  ·  Esc"
        )
        footerLabel.font = Tokens.TypeScale.footnote
        footerLabel.textColor = Tokens.System.tertiaryLabel
        footerLabel.alignment = .center
        footerLabel.frame = NSRect(x: inset, y: 8, width: panelWidth - inset * 2, height: 14)
        rootView.addSubview(footerLabel)

        super.init()

        searchField.delegate = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(confirmCopy)
        tableView.target = self

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func show() {
        reloadItems()
        positionOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        suppressResignHide = true
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.makeKey()
            _ = self.panel.makeFirstResponder(self.searchField)
            self.suppressResignHide = false
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
        let x = vis.midX - panelWidth / 2
        let y = vis.midY - panelHeight / 2 + 40
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func reloadItems() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let all = try core.clipboard.all(limit: 500)
            if q.isEmpty {
                items = all
            } else {
                let lower = q.lowercased()
                items = all.filter { $0.text.lowercased().contains(lower) }
            }
        } catch {
            items = []
        }
        selectedIndex = min(selectedIndex, max(0, items.count - 1))
        emptyLabel.isHidden = !items.isEmpty
        if items.isEmpty {
            emptyLabel.stringValue = q.isEmpty
                ? "No clipboard history yet — copy something"
                : "No matches"
        }
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        selectedIndex = 0
        reloadItems()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LauncherTableRowView()
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 { selectedIndex = row }
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : panelWidth - 24
        let rowH = Tokens.Metrics.rowHeight
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: width, height: rowH))

        let pin = NSTextField(labelWithString: item.isPinned ? "📌" : "")
        pin.frame = NSRect(x: 10, y: (rowH - 16) / 2, width: 20, height: 16)
        pin.font = .systemFont(ofSize: 12)

        let preview = item.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = NSTextField(labelWithString: String(preview.prefix(120)))
        title.frame = NSRect(x: 32, y: 22, width: max(40, width - 44), height: 16)
        title.font = Tokens.TypeScale.rowTitle
        title.textColor = Tokens.System.label
        title.lineBreakMode = .byTruncatingTail

        let metaParts = [
            item.sourceApp,
            relativeTime(item.createdAt),
        ].compactMap { $0 }
        let sub = NSTextField(labelWithString: metaParts.joined(separator: " · "))
        sub.frame = NSRect(x: 32, y: 6, width: max(40, width - 44), height: 14)
        sub.font = Tokens.TypeScale.rowSubtitle
        sub.textColor = Tokens.System.secondaryLabel
        sub.lineBreakMode = .byTruncatingMiddle

        cell.addSubview(pin)
        cell.addSubview(title)
        cell.addSubview(sub)
        cell.textField = title
        cell.setAccessibilityLabel(preview)
        return cell
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    @objc private func confirmCopy() {
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string], owner: nil)
        pb.setString(item.text, forType: .string)
        hide()
    }

    private func deleteSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        let id = items[selectedIndex].id
        _ = try? core.dispatch(action: .clipboardDelete(id: id), actor: .user)
        reloadItems()
    }

    private func togglePinSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        _ = try? core.dispatch(
            action: .clipboardPin(id: item.id, pinned: !item.isPinned),
            actor: .user
        )
        reloadItems()
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible, panel.isKeyWindow || NSApp.keyWindow === panel else {
            return event
        }
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 125:
            selectedIndex = min(selectedIndex + 1, max(0, items.count - 1))
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
            return nil
        case 126:
            selectedIndex = max(selectedIndex - 1, 0)
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
            return nil
        case 36:
            confirmCopy()
            return nil
        case 53:
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                selectedIndex = 0
                reloadItems()
            } else {
                hide()
            }
            return nil
        case 51 where cmd: // ⌘⌫
            deleteSelected()
            return nil
        case 35 where cmd: // ⌘P
            togglePinSelected()
            return nil
        default:
            return event
        }
    }
}
