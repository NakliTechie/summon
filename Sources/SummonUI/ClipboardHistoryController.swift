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
    private let rootView: AppearanceAwareView
    private var effectView: NSVisualEffectView?
    private let panelWidth: CGFloat = 420
    private let panelHeight: CGFloat = 480
    private var items: [ClipboardItemSummary] = []
    private let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()
    private var selectedIndex: Int = 0
    private var resignHideWork: DispatchWorkItem?
    private var suppressResignHide = false
    private var ignoreListController: ClipboardIgnoreListController?
    private var eventMonitor: Any?
    private let reloadQueue = DispatchQueue(label: "summon.clipboard-history.reload", qos: .userInitiated)
    private var reloadGeneration: UInt64 = 0

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
        rootView = AppearanceAwareView(frame: rect)
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = Tokens.Metrics.panelCornerRadius
        if #available(macOS 11.0, *) {
            rootView.layer?.cornerCurve = .continuous
        }
        rootView.layer?.masksToBounds = true
        rootView.layer?.borderWidth = 1
        panel.contentView = rootView

        let effect = NSVisualEffectView(frame: rootView.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        rootView.addSubview(effect, positioned: .below, relativeTo: nil)
        effectView = effect

        let inset = Tokens.Metrics.contentInset
        let title = NSTextField(labelWithString: "Clipboard")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Tokens.System.secondaryLabel
        title.frame = NSRect(x: inset, y: panelHeight - 28, width: 200, height: 16)
        rootView.addSubview(title)

        let ignoreButton = NSButton(title: "Ignored Apps…", target: nil, action: nil)
        ignoreButton.frame = NSRect(x: panelWidth - 180, y: panelHeight - 34, width: 104, height: 24)
        ignoreButton.bezelStyle = .inline
        ignoreButton.font = Tokens.TypeScale.footnote
        rootView.addSubview(ignoreButton)

        let clearButton = NSButton(title: "Clear…", target: nil, action: nil)
        clearButton.frame = NSRect(x: panelWidth - 76, y: panelHeight - 34, width: 64, height: 24)
        clearButton.bezelStyle = .inline
        clearButton.font = Tokens.TypeScale.footnote
        rootView.addSubview(clearButton)

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
            frame: NSRect(x: 4, y: 44, width: panelWidth - 8, height: panelHeight - 70 - 44)
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
        tableView.setAccessibilityRole(.list)
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
            labelWithString: "↑↓ Navigate  ·  ↩ Copy  ·  ⌘⌫ Delete\n"
                + "⌘P Pin  ·  \(ShortcutCatalog.clearClipboardHistory) Clear  ·  "
                + "\(ShortcutCatalog.clipboardHistory) Open  ·  Esc Close"
        )
        footerLabel.font = Tokens.TypeScale.footnote
        footerLabel.textColor = Tokens.System.tertiaryLabel
        footerLabel.alignment = .center
        footerLabel.maximumNumberOfLines = 2
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.frame = NSRect(x: inset, y: 6, width: panelWidth - inset * 2, height: 30)
        rootView.addSubview(footerLabel)

        super.init()

        configureObservers()
        refreshAppearance()

        searchField.delegate = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(confirmCopy)
        tableView.target = self
        ignoreButton.target = self
        ignoreButton.action = #selector(showIgnoreList)
        clearButton.target = self
        clearButton.action = #selector(requestClearHistory)

    }

    private func configureObservers() {
        rootView.appearanceDidChange = { [weak self] in self?.refreshAppearance() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
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
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    public func show() {
        searchField.stringValue = ""
        selectedIndex = 0
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
        reloadGeneration &+= 1
        searchField.stringValue = ""
        selectedIndex = 0
        panel.orderOut(nil)
    }

    public func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    @objc public func showIgnoreList() {
        hide()
        if ignoreListController == nil {
            ignoreListController = ClipboardIgnoreListController(core: core)
        }
        ignoreListController?.show()
    }

    @objc public func requestClearHistory() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear Clipboard History?"
        alert.informativeText = "This removes every unpinned clipboard item and its journaled content. Pinned items remain."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try core.dispatch(action: .clipboardClearUnpinned, actor: .user)
            reloadItems()
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = "Clipboard history was not cleared."
            failure.informativeText = "Summon could not update its local store. Try again after closing other Summon commands."
            failure.runModal()
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
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let clipboard = core.clipboard
        reloadQueue.async { [weak self] in
            let loaded = (try? q.isEmpty
                ? clipboard.metadataPage(perBucketLimit: 500)
                : clipboard.matchingMetadataPage(q, perBucketLimit: 500)) ?? []
            DispatchQueue.main.async {
                guard let self, self.reloadGeneration == generation else { return }
                self.applyReloadedItems(loaded, query: q)
            }
        }
    }

    private func applyReloadedItems(_ loaded: [ClipboardItemSummary], query: String) {
        items = loaded
        selectedIndex = min(selectedIndex, max(0, items.count - 1))
        emptyLabel.isHidden = !items.isEmpty
        if items.isEmpty {
            emptyLabel.stringValue = query.isEmpty
                ? "No clipboard history yet — copy something"
                : "No matches"
        }
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        refreshAppearance()
    }

    private func refreshAppearance() {
        rootView.effectiveAppearance.performAsCurrentDrawingAppearance {
            rootView.layer?.borderColor = Tokens.System.separator.withAlphaComponent(0.45).cgColor
            let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            rootView.layer?.backgroundColor = reduceTransparency
                ? Tokens.System.windowBackground.cgColor
                : NSColor.clear.cgColor
            effectView?.isHidden = reduceTransparency
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

        let titleX: CGFloat
        if item.contentKind == .image {
            let imageView = NSImageView(frame: NSRect(x: 10, y: 7, width: 40, height: 40))
            imageView.image = thumbnail(for: item)
                ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "Image")
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 5
            imageView.layer?.masksToBounds = true
            cell.addSubview(imageView)
            titleX = 58
        } else {
            let pin = NSTextField(labelWithString: item.isPinned ? "📌" : "")
            pin.frame = NSRect(x: 10, y: (rowH - 16) / 2, width: 20, height: 16)
            pin.font = .systemFont(ofSize: 12)
            cell.addSubview(pin)
            titleX = 32
        }

        let preview = item.displayText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pinPrefix = item.contentKind == .image && item.isPinned ? "📌 " : ""
        let title = NSTextField(labelWithString: pinPrefix + String(preview.prefix(120)))
        title.frame = NSRect(x: titleX, y: 22, width: max(40, width - titleX - 12), height: 16)
        title.font = Tokens.TypeScale.rowTitle
        title.textColor = Tokens.System.label
        title.lineBreakMode = .byTruncatingTail

        let metaParts = [
            contentLabel(item),
            item.sourceApp,
            relativeTime(item.createdAt),
        ].compactMap { $0 }
        let sub = NSTextField(labelWithString: metaParts.joined(separator: " · "))
        sub.frame = NSRect(x: titleX, y: 6, width: max(40, width - titleX - 12), height: 14)
        sub.font = Tokens.TypeScale.rowSubtitle
        sub.textColor = Tokens.System.secondaryLabel
        sub.lineBreakMode = .byTruncatingMiddle

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

    private func contentLabel(_ item: ClipboardItemSummary) -> String? {
        switch item.contentKind {
        case .plainText: return nil
        case .richText: return item.flavor == "public.html" ? "HTML" : "Rich Text"
        case .image: return "Image"
        case .file: return "File"
        }
    }

    private func thumbnail(for item: ClipboardItemSummary) -> NSImage? {
        let key = item.id as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        guard let stored = try? core.clipboard.get(id: item.id),
              let data = stored.data,
              let image = NSImage(data: data) else {
            return nil
        }
        thumbnailCache.setObject(image, forKey: key, cost: data.count)
        return image
    }

    @objc private func confirmCopy() {
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        var payload: [String: JSONValue] = [
            "clipboardID": .string(item.id),
            "text": .string(item.text),
            "pinned": .bool(item.isPinned),
            "contentKind": .string(item.contentKind.rawValue),
        ]
        if let flavor = item.flavor { payload["flavor"] = .string(flavor) }
        let result = SearchResult(
            id: "clipboard:\(item.id)",
            title: item.displayText,
            kind: .clipboard,
            payload: payload
        )
        if let detail = ClipboardActionFeedback.failureDetail(
            label: "Copy Clipboard Item",
            failureContext: "write to the pasteboard",
            operation: {
                try core.invoke(actionName: "clipboard.copy", result: result, actor: .user)
            }
        ) {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Copy Failed"
            alert.informativeText = "\(detail) Try copying the item again."
            alert.runModal()
            return
        }
        hide()
    }

    private func deleteSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        let id = items[selectedIndex].id
        performMutation(label: "Delete Clipboard Item") {
            try core.dispatch(action: .clipboardDelete(id: id), actor: .user)
        }
    }

    private func togglePinSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        performMutation(label: item.isPinned ? "Unpin Clipboard Item" : "Pin Clipboard Item") {
            try core.dispatch(
                action: .clipboardPin(id: item.id, pinned: !item.isPinned),
                actor: .user
            )
        }
    }

    private func performMutation(
        label: String,
        operation: () throws -> ActionResult
    ) {
        if let detail = ClipboardActionFeedback.failureDetail(
            label: label,
            failureContext: "update the local store",
            operation: operation
        ) {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "\(label) Failed"
            alert.informativeText = detail
            alert.runModal()
            return
        }
        reloadItems()
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible, panel.isKeyWindow || NSApp.keyWindow === panel else {
            return event
        }
        return handleFocusedKey(event)
    }

    func handleFocusedKey(_ event: NSEvent) -> NSEvent? {
        let editor = searchField.currentEditor() as? NSTextView
        let isEditingSearch = panel.firstResponder === editor || panel.firstResponder === searchField
        if editor?.hasMarkedText() == true, [36, 125, 126].contains(event.keyCode) {
            return event
        }
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
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
        case 51 where cmd && shift: // ⌘⇧⌫
            requestClearHistory()
            return nil
        case 51 where cmd && !shift
            && (!isEditingSearch || searchField.stringValue.isEmpty): // ⌘⌫
            deleteSelected()
            return nil
        case 35 where cmd && !isEditingSearch: // ⌘P
            togglePinSelected()
            return nil
        default:
            return event
        }
    }
}

enum ClipboardActionFeedback {
    static func failureDetail(
        label: String,
        failureContext: String,
        operation: () throws -> ActionResult
    ) -> String? {
        do {
            switch try operation().outcome {
            case .applied:
                return nil
            case .rejected(let reason):
                return "\(label) could not \(failureContext): \(reason)"
            case .staged:
                return "\(label) was staged for approval instead of being applied."
            }
        } catch {
            let reason = (error as? CoreError)?.message ?? error.localizedDescription
            return "\(label) could not \(failureContext): \(reason)"
        }
    }
}
