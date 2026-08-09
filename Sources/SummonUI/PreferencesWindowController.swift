import AppKit
import Foundation
import SummonCore

/// Native task-grouped configuration surface. Advanced features remain explicit and default off.
public final class PreferencesWindowController: NSWindowController, NSTextFieldDelegate {
    private let core: SummonCore
    private let onOpenClipboard: () -> Void
    private let onOpenIgnoreList: () -> Void
    private let onLoginItemChanged: () -> Void
    private let tabs = NSTabViewController()

    private let loginToggle = NSButton(checkboxWithTitle: "Keep Summon ready at login", target: nil, action: nil)
    private let ftsToggle = NSButton(checkboxWithTitle: "Index local content for full-text search", target: nil, action: nil)
    private let webToggle = NSButton(checkboxWithTitle: "Search the web", target: nil, action: nil)
    private let defaultActionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let webURLField = NSTextField(string: "")
    private let agentToggle = NSButton(checkboxWithTitle: "Enable the local agent socket", target: nil, action: nil)
    private let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let webSetupButton = NSButton(title: "Set up full web search", target: nil, action: nil)
    private let webSetupStatus = NSTextField(labelWithString: "")
    private let onSetUpWebSearch: ((@escaping @MainActor (WebSearchInstaller.Phase) -> Void) -> Void)?

    public init(
        core: SummonCore,
        onOpenClipboard: @escaping () -> Void,
        onOpenIgnoreList: @escaping () -> Void,
        onLoginItemChanged: @escaping () -> Void,
        onSetUpWebSearch: ((@escaping @MainActor (WebSearchInstaller.Phase) -> Void) -> Void)? = nil
    ) {
        self.core = core
        self.onOpenClipboard = onOpenClipboard
        self.onOpenIgnoreList = onOpenIgnoreList
        self.onLoginItemChanged = onLoginItemChanged
        self.onSetUpWebSearch = onSetUpWebSearch

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Summon Preferences"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        tabs.tabStyle = .toolbar
        tabs.addChild(makeGeneralTab())
        tabs.addChild(makeSearchTab())
        tabs.addChild(makeClipboardTab())
        tabs.addChild(makeAutomationTab())
        tabs.addChild(makeAppearanceTab())
        window.contentViewController = tabs

        configureActions()
        refresh()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func show(section: PreferencesSection = .general) {
        refresh()
        if let index = PreferencesSection.allCases.firstIndex(of: section) {
            tabs.selectedTabViewItemIndex = index
        }
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureActions() {
        loginToggle.target = self
        loginToggle.action = #selector(changeLoginItem)
        ftsToggle.target = self
        ftsToggle.action = #selector(changeFTS)
        webToggle.target = self
        webToggle.action = #selector(changeWeb)
        defaultActionPopup.target = self
        defaultActionPopup.action = #selector(changeDefaultAction)
        webURLField.delegate = self
        webURLField.target = self
        webURLField.action = #selector(changeWebURL)
        agentToggle.target = self
        agentToggle.action = #selector(changeAgentSocket)
        appearancePopup.target = self
        appearancePopup.action = #selector(changeAppearance)
        webSetupButton.target = self
        webSetupButton.action = #selector(setUpWebSearch)
    }

    private func refresh() {
        loginToggle.state = LoginItemService.isEnabled ? .on : .off
        ftsToggle.state = core.search.ftsEnabled ? .on : .off
        webToggle.state = core.webConfig.enabled ? .on : .off
        defaultActionPopup.selectItem(
            withTitle: Self.defaultActionTitle(for: settingString("search.defaultAction") ?? "auto")
        )
        webURLField.stringValue = core.webConfig.baseURL
        agentToggle.state = settingBool("agent.socket.enabled") ? .on : .off
        let appearance = settingString("theme.appearance") ?? "system"
        appearancePopup.selectItem(withTitle: appearance.capitalized)
    }

    private func makeGeneralTab() -> NSViewController {
        let details = label(
            "Summon stays resident so ⌥Space and local clipboard history remain available. "
                + "Launch at login is recommended, but Summon changes it only after your choice."
        )
        let shortcuts = label(
            "Launcher: \(ShortcutCatalog.launcher)\n"
                + "Clipboard history: \(ShortcutCatalog.clipboardHistory)\n"
                + "Window shortcuts: \(WindowShortcut.defaultSummary)\n"
                + "Window actions affect the focused window on the active Space only."
        )
        return tab(
            section: .general,
            views: [heading("Startup and shortcuts"), details, loginToggle, separator(), shortcuts]
        )
    }

    private func makeSearchTab() -> NSViewController {
        let ftsDetails = label(
            "Content search reads local document text into Summon's local FTS index. "
                + "Enabling it asks for explicit consent."
        )
        let webDetails = label(
            "Web search is on by default. A question can be answered on-device or by "
                + "searching the web; your query goes only to the provider below (the "
                + "keyless Wikipedia floor, or your SearXNG if set), the answer is composed "
                + "on this Mac, and the first web search always asks permission."
        )
        defaultActionPopup.addItems(
            withTitles: ["Automatic", "Local answer first", "Web search first"]
        )
        let defaultRow = NSStackView(views: [label("Default for a question"), defaultActionPopup])
        defaultRow.orientation = .horizontal
        defaultRow.spacing = 12
        let urlRow = NSStackView(views: [label("SearXNG URL"), webURLField])
        urlRow.orientation = .horizontal
        urlRow.spacing = 12
        webURLField.placeholderString = "http://127.0.0.1:8080"
        webURLField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        webSetupStatus.font = .systemFont(ofSize: 11)
        webSetupStatus.textColor = .secondaryLabelColor
        let setupDetails = label(
            "Full web search runs an opt-in SearXNG on Apple's container runtime "
                + "(reusing Docker if present). One click sets it up in the background — "
                + "the launcher stays usable throughout."
        )
        return tab(
            section: .search,
            views: [
                heading("Search and indexing"), ftsDetails, ftsToggle, separator(),
                webDetails, webToggle, defaultRow, urlRow,
                separator(), setupDetails, webSetupButton, webSetupStatus,
            ]
        )
    }

    private func makeClipboardTab() -> NSViewController {
        let details = label(
            "Clipboard history stays on this Mac. Concealed items are skipped. "
                + "Unpinned history is capped at 500 items."
        )
        let history = NSButton(title: "Open Clipboard History", target: self, action: #selector(openClipboard))
        let ignore = NSButton(title: "Manage Ignored Applications…", target: self, action: #selector(openIgnoreList))
        return tab(
            section: .clipboard,
            views: [heading("Clipboard and privacy"), details, history, ignore]
        )
    }

    private func makeAutomationTab() -> NSViewController {
        let details = label(
            "The agent socket is local, same-user only, and default off. "
                + "Sensitive reads require a separate grant. Elevated actions require human review."
        )
        return tab(
            section: .automation,
            views: [heading("Automation and agents"), details, agentToggle]
        )
    }

    private func makeAppearanceTab() -> NSViewController {
        appearancePopup.addItems(withTitles: ["System", "Dark", "Light"])
        let details = label("Choose whether Summon follows macOS or uses a fixed appearance.")
        return tab(
            section: .appearance,
            views: [heading("Appearance"), details, appearancePopup]
        )
    }

    private func tab(section: PreferencesSection, views: [NSView]) -> NSViewController {
        let controller = NSViewController()
        controller.title = section.rawValue
        let root = NSView()
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
        ])
        controller.view = root
        return controller
    }

    private func heading(_ text: String) -> NSTextField {
        let field = label(text)
        field.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        field.textColor = Tokens.System.label
        return field
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = Tokens.TypeScale.rowTitle
        field.textColor = Tokens.System.secondaryLabel
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = 540
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 540).isActive = true
        return box
    }

    @objc private func changeLoginItem() {
        let requested = loginToggle.state == .on
        guard LoginItemService.setEnabled(requested) else {
            refresh()
            showError("Summon could not change the login item.")
            return
        }
        do {
            _ = try core.dispatch(
                action: .settingsSet(key: LoginItemService.settingsKey, value: .bool(LoginItemService.isEnabled)),
                actor: .user
            )
            onLoginItemChanged()
        } catch {
            refresh()
            showError(error.localizedDescription)
        }
    }

    @objc private func changeFTS() {
        let requested = ftsToggle.state == .on
        do {
            if requested, !core.ftsConsentGranted() {
                let alert = NSAlert()
                alert.messageText = "Enable local content search?"
                alert.informativeText = "Summon will index local document text in its on-device database."
                alert.addButton(withTitle: "Enable Content Search")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    ftsToggle.state = .off
                    return
                }
                try core.grantFTSConsent(actor: .user)
            }
            try core.setFTSEnabled(requested, actor: .user)
        } catch {
            refresh()
            showError(error.localizedDescription)
        }
    }

    @objc private func changeWeb() {
        core.webConfig.enabled = webToggle.state == .on
        persistWeb()
    }

    @objc private func setUpWebSearch() {
        guard let onSetUpWebSearch else { return }
        webSetupButton.isEnabled = false
        webSetupStatus.stringValue = WebSearchInstaller.Phase.detecting.statusText
        webSetupStatus.textColor = .secondaryLabelColor
        onSetUpWebSearch { @MainActor [weak self] phase in
            guard let self else { return }
            self.webSetupStatus.stringValue = phase.statusText
            self.webSetupStatus.textColor = phase.isError ? .systemRed : .secondaryLabelColor
            if phase.isTerminal {
                self.webSetupButton.isEnabled = true
                if case .enabled = phase { self.refresh() }
            }
        }
    }

    @objc private func changeDefaultAction() {
        let value = Self.defaultActionValue(for: defaultActionPopup.titleOfSelectedItem ?? "Automatic")
        do {
            _ = try core.dispatch(
                action: .settingsSet(key: "search.defaultAction", value: .string(value)),
                actor: .user
            )
        } catch {
            refresh()
            showError(error.localizedDescription)
        }
    }

    /// Preference popup title ↔ stored value (auto | local | search).
    private static func defaultActionTitle(for value: String) -> String {
        switch value {
        case "local": return "Local answer first"
        case "search": return "Web search first"
        default: return "Automatic"
        }
    }

    private static func defaultActionValue(for title: String) -> String {
        switch title {
        case "Local answer first": return "local"
        case "Web search first": return "search"
        default: return "auto"
        }
    }

    @objc private func changeWebURL() {
        core.webConfig.baseURL = webURLField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        persistWeb()
    }

    private func persistWeb() {
        do {
            let result = try core.persistWebConfig(actor: .user)
            guard result.isApplied else {
                throw CoreError.store("web search configuration was not applied")
            }
        } catch {
            refresh()
            showError(error.localizedDescription)
        }
    }

    @objc private func changeAgentSocket() {
        do {
            _ = try core.dispatch(
                action: .settingsSet(key: "agent.socket.enabled", value: .bool(agentToggle.state == .on)),
                actor: .user
            )
        } catch {
            refresh()
            showError(error.localizedDescription)
        }
    }

    @objc private func changeAppearance() {
        let raw = (appearancePopup.titleOfSelectedItem ?? "System").lowercased()
        do {
            _ = try core.dispatch(
                action: .settingsSet(key: "theme.appearance", value: .string(raw)),
                actor: .user
            )
            switch raw {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: NSApp.appearance = nil
            }
        } catch {
            refresh()
            showError(error.localizedDescription)
        }
    }

    @objc private func openClipboard() {
        window?.orderOut(nil)
        onOpenClipboard()
    }

    @objc private func openIgnoreList() {
        window?.orderOut(nil)
        onOpenIgnoreList()
    }

    private func settingBool(_ key: String) -> Bool {
        (try? core.settings.get(key))?.boolValue ?? false
    }

    private func settingString(_ key: String) -> String? {
        (try? core.settings.get(key))?.stringValue
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Preference not changed"
        alert.informativeText = message
        alert.runModal()
    }
}
