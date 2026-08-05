import AppKit
import SummonCore

/// User-facing editor for the per-app clipboard ignore list.
public final class ClipboardIgnoreListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    public let panel: NSPanel
    private let core: SummonCore
    private let entryField: NSTextField
    private let tableView: NSTableView
    private let statusLabel: NSTextField
    private var entries: [String] = []

    public init(core: SummonCore) {
        self.core = core
        let rect = NSRect(x: 0, y: 0, width: 440, height: 320)
        panel = NSPanel(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Clipboard Ignore List"
        panel.isReleasedWhenClosed = false
        panel.level = .floating

        let root = NSView(frame: rect)
        panel.contentView = root

        let description = NSTextField(
            wrappingLabelWithString: "Summon will not store clipboard changes from these app names or bundle identifiers."
        )
        description.frame = NSRect(x: 20, y: 270, width: 400, height: 34)
        description.textColor = .secondaryLabelColor
        root.addSubview(description)

        entryField = NSTextField(frame: NSRect(x: 20, y: 232, width: 300, height: 26))
        entryField.placeholderString = "App name or bundle ID"
        entryField.setAccessibilityLabel("App name or bundle identifier")
        root.addSubview(entryField)

        let addButton = NSButton(title: "Add", target: nil, action: nil)
        addButton.frame = NSRect(x: 330, y: 230, width: 90, height: 30)
        addButton.bezelStyle = .rounded
        root.addSubview(addButton)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 62, width: 400, height: 158))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        tableView = NSTableView(frame: scroll.bounds)
        tableView.headerView = nil
        tableView.rowHeight = 26
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ignore-entry"))
        column.width = 382
        tableView.addTableColumn(column)
        scroll.documentView = tableView
        root.addSubview(scroll)

        let removeButton = NSButton(title: "Remove Selected", target: nil, action: nil)
        removeButton.frame = NSRect(x: 20, y: 22, width: 130, height: 30)
        removeButton.bezelStyle = .rounded
        root.addSubview(removeButton)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 160, y: 28, width: 260, height: 18)
        statusLabel.alignment = .right
        statusLabel.textColor = .secondaryLabelColor
        root.addSubview(statusLabel)

        super.init()

        tableView.dataSource = self
        tableView.delegate = self
        addButton.target = self
        addButton.action = #selector(addEntry)
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        entryField.target = self
        entryField.action = #selector(addEntry)
    }

    public func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(entryField)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ignore-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        let label: NSTextField
        if let existing = cell.textField {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            label.frame = NSRect(x: 8, y: 4, width: 360, height: 18)
            label.autoresizingMask = [.width]
            cell.addSubview(label)
            cell.textField = label
        }
        label.stringValue = entries[row]
        cell.setAccessibilityLabel(entries[row])
        return cell
    }

    @objc private func addEntry() {
        let entry = entryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else {
            statusLabel.stringValue = "Enter an app name or bundle ID."
            return
        }
        do {
            _ = try core.dispatch(action: .clipboardIgnoreAdd(entry: entry), actor: .user)
            entryField.stringValue = ""
            statusLabel.stringValue = "Added."
            reload()
        } catch {
            statusLabel.stringValue = "Could not update the ignore list."
        }
    }

    @objc private func removeSelected() {
        let row = tableView.selectedRow
        guard entries.indices.contains(row) else {
            statusLabel.stringValue = "Select an entry to remove."
            return
        }
        do {
            _ = try core.dispatch(action: .clipboardIgnoreRemove(entry: entries[row]), actor: .user)
            statusLabel.stringValue = "Removed."
            reload()
        } catch {
            statusLabel.stringValue = "Could not update the ignore list."
        }
    }

    private func reload() {
        do {
            entries = try core.clipboardIgnore.all()
            tableView.reloadData()
        } catch {
            entries = []
            tableView.reloadData()
            statusLabel.stringValue = "Could not load the ignore list."
        }
    }
}
