import AppKit
import Foundation
import SummonCore

/// AppKit launcher panel — search field + results list driven by `LauncherSession`.
/// HUD material; solid `bg.glass` when Reduce Transparency is on.
public final class LauncherPanelController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public let session: LauncherSession
    public let panel: NSPanel
    private let searchField: NSTextField
    private let tableView: NSTableView
    private let emptyLabel: NSTextField
    private let scrollView: NSScrollView
    private var effectView: NSVisualEffectView?

    public init(core: SummonCore) {
        self.session = LauncherSession(core: core)

        let width: CGFloat = 640
        let height: CGFloat = 420
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
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

        // Background material
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

        searchField = NSTextField(frame: NSRect(x: 16, y: height - 52, width: width - 32, height: 28))
        searchField.placeholderString = "Search apps, files, clipboard…"
        searchField.font = NSFont.systemFont(ofSize: 16)
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.backgroundColor = .clear
        searchField.textColor = Tokens.Color.text.nsColor
        content.addSubview(searchField)

        scrollView = NSScrollView(frame: NSRect(x: 8, y: 8, width: width - 16, height: height - 68))
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
        col.width = width - 32
        tableView.addTableColumn(col)
        scrollView.documentView = tableView
        content.addSubview(scrollView)

        emptyLabel = NSTextField(labelWithString: "Type to search — apps, files, clipboard, snippets")
        emptyLabel.textColor = Tokens.Color.textDim.nsColor
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.alignment = .center
        emptyLabel.frame = NSRect(x: 16, y: height / 2 - 10, width: width - 32, height: 20)
        content.addSubview(emptyLabel)

        super.init()

        searchField.delegate = self
        tableView.dataSource = self
        tableView.delegate = self

        // Local key monitor for arrows / return / tab / escape
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }

        reloadUI()
    }

    public func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        NSApp.activate(ignoringOtherApps: true)
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

    // MARK: - NSTextFieldDelegate

    public func controlTextDidChange(_ obj: Notification) {
        let text = searchField.stringValue
        do {
            _ = try session.setQuery(text)
            reloadUI()
        } catch {
            // Keep last good results; surface later via status line.
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
            label.stringValue = "[\(r.kind.rawValue)] \(r.title)\(sub)"
        }
        cell.addSubview(label)
        return cell
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard panel.isKeyWindow || panel.isVisible else { return event }
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
        let empty = session.objectMode ? session.objectActions.isEmpty : session.results.isEmpty
        emptyLabel.isHidden = !empty || !searchField.stringValue.isEmpty && !empty
        emptyLabel.isHidden = !(session.results.isEmpty && session.objectActions.isEmpty)
        if searchField.stringValue.isEmpty && session.results.isEmpty {
            emptyLabel.stringValue = "Type to search — apps, files, clipboard, snippets"
            emptyLabel.isHidden = false
        } else if session.results.isEmpty && !session.objectMode {
            emptyLabel.stringValue = "No results"
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
        tableView.reloadData()
        let idx = session.selectedIndex
        if idx >= 0, numberOfRows(in: tableView) > idx {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        }
    }
}
