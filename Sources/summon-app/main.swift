import AppKit
import Carbon
import Foundation
import SummonCore
import SummonUI
#if SUMMON_AI
import SummonAI
#endif

/// Menu-bar host: ⌥Space launcher, ⌥⇧C clipboard history, resident pasteboard capture, login item.
@main
enum SummonAppMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var core: SummonCore!
    var panel: LauncherPanelController!
    var clipboardHistory: ClipboardHistoryController!
    var preferences: PreferencesWindowController?
    var pasteboard: PasteboardService!
    var hotkey: GlobalHotkey?
    var clipboardHotkey: GlobalHotkey?
    var windowHotkeys: [GlobalHotkey] = []
    var windowShortcutRegistrationErrors: [String] = []
    var windowShortcutLastError: String?
    var agentSocketLifecycle: AgentSocketLifecycleController?
    var agentSocketMonitor: Timer?
    var agentSocketError: String?
    var statusItem: NSStatusItem?
    var accessibilityStatusItem: NSMenuItem?
    var primaryHotkeyLabel = "⌥Space"
    var primaryHotkeyError: String?
    let loginChoicePromptedKey = "onboarding.loginChoicePrompted"
    #if SUMMON_AI
    var aiService: SummonAIService?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            core = try SummonCore()
            for warning in core.startupWarnings {
                fputs("Summon startup warning: \(warning)\n", stderr)
            }
            let needsFirstRunLoginChoice = shouldOfferFirstRunLoginChoice()

            #if SUMMON_AI
            let service = SummonAIService(core: core)
            aiService = service
            panel = LauncherPanelController(
                core: core,
                aiIntegration: makeAIIntegration(service: service),
                onNavigate: { [weak self] destination in self?.open(destination: destination) }
            )
            #else
            panel = LauncherPanelController(
                core: core,
                onNavigate: { [weak self] destination in self?.open(destination: destination) }
            )
            #endif
            clipboardHistory = ClipboardHistoryController(core: core)
            core.setExecutor(
                ProcessModuleExecutor(
                    pasteboardWriter: { text in
                        try PasteboardService.writeGeneratedText(text)
                    },
                    clipboardWriter: { item, asPlainText in
                        try PasteboardService.writeGeneratedItem(item, asPlainText: asPlainText)
                    },
                    destinationOpener: { [weak self] destination in
                        DispatchQueue.main.async {
                            self?.open(destination: destination)
                        }
                    },
                    windowArranger: { layout, gap in
                        try WindowApplicator.apply(layout: layout, gap: gap)
                    }
                )
            )

            LoginItemService.reconcileIfConfigured(core: core)

            // CB-1: resident capture for process lifetime (panel need not be open).
            pasteboard = PasteboardService(core: core)
            pasteboard.startPolling()

            // Preserve the resident app and menu fallback when the preferred key is occupied.
            hotkey = GlobalHotkey(id: 1)
            hotkey?.onPressed = { [weak self] in
                self?.clipboardHistory.hide()
                self?.panel.toggle()
            }
            registerPrimaryHotkey()
            registerWindowHotkeys()

            // Clipboard hotkey is optional (another app may own ⌥⇧C).
            clipboardHotkey = GlobalHotkey(id: 2)
            clipboardHotkey?.onPressed = { [weak self] in
                self?.panel.hide()
                self?.clipboardHistory.toggle()
            }
            do {
                try clipboardHotkey?.register(
                    keyCode: UInt32(kVK_ANSI_C),
                    modifiers: UInt32(optionKey | shiftKey)
                )
            } catch {
                fputs(
                    "Summon: clipboard hotkey \(ShortcutCatalog.clipboardHistory) not registered: \(error)\n",
                    stderr
                )
            }

            startAgentSocketMonitoring()
            installStatusItem()
            if needsFirstRunLoginChoice {
                panel.show(markFirstRunSeen: false)
                DispatchQueue.main.async { [weak self] in
                    self?.offerFirstRunLoginChoice()
                }
            }
        } catch {
            fputs("Summon failed to start: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private func installStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        if let button = statusItem?.button {
            if let img = NSImage(
                systemSymbolName: "magnifyingglass",
                accessibilityDescription: "Summon"
            ) {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "∑"
            }
            button.toolTip = "Summon \(SummonVersion.string)"
        }
        let menu = NSMenu()
        menu.delegate = self
        for warning in core.startupWarnings {
            let warningItem = NSMenuItem(
                title: "Store Warning: \(String(warning.prefix(160)))",
                action: nil,
                keyEquivalent: ""
            )
            warningItem.isEnabled = false
            menu.addItem(warningItem)
        }
        if !core.startupWarnings.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }
        menu.addItem(NSMenuItem(
            title: "Show Launcher",
            action: #selector(showLauncher),
            keyEquivalent: ""
        ))
        let clipItem = NSMenuItem(
            title: "Clipboard History",
            action: #selector(showClipboard),
            keyEquivalent: "c"
        )
        clipItem.keyEquivalentModifierMask = [.option, .shift]
        menu.addItem(clipItem)
        let shortcutStatus = NSMenuItem(
            title: primaryHotkeyError == nil
                ? "Launcher Shortcut: \(primaryHotkeyLabel)"
                : "Launcher Shortcut Unavailable — use Show Launcher",
            action: nil,
            keyEquivalent: ""
        )
        shortcutStatus.isEnabled = false
        menu.addItem(shortcutStatus)
        menu.addItem(makeWindowShortcutMenuItem())
        if let windowShortcutLastError {
            let errorItem = NSMenuItem(
                title: "Window Action: \(String(windowShortcutLastError.prefix(160)))",
                action: nil,
                keyEquivalent: ""
            )
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }
        menu.addItem(NSMenuItem(
            title: "Clear Clipboard History…",
            action: #selector(clearClipboardHistory),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Manage Ignored Applications…",
            action: #selector(showClipboardIgnoreList),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Preferences…",
            action: #selector(showPreferencesMenu),
            keyEquivalent: ","
        ))
        #if SUMMON_AI
        menu.addItem(NSMenuItem(
            title: "AI Status…",
            action: #selector(showAIStatus),
            keyEquivalent: ""
        ))
        #endif
        menu.addItem(NSMenuItem.separator())
        let login = NSMenuItem(
            title: LoginItemService.isEnabled ? "Launch at Login ✓" : "Launch at Login",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        menu.addItem(login)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Summon",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem?.menu = menu
    }

    private func makeWindowShortcutMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(
            title: StatusMenuPresentation.windowShortcutsTitle(
                registered: windowHotkeys.count,
                total: WindowShortcut.defaults.count
            ),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: "Window Shortcuts")
        let accessibilityStatus = NSMenuItem(
            title: StatusMenuPresentation.accessibilityTitle(
                isTrusted: PermissionStatus.snapshot().accessibilityTrusted
            ),
            action: nil,
            keyEquivalent: ""
        )
        accessibilityStatusItem = accessibilityStatus
        accessibilityStatus.isEnabled = false
        submenu.addItem(accessibilityStatus)
        submenu.addItem(NSMenuItem.separator())
        for shortcut in WindowShortcut.defaults {
            let item = NSMenuItem(title: shortcut.menuTitle, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    func menuWillOpen(_ menu: NSMenu) {
        accessibilityStatusItem?.title = StatusMenuPresentation.accessibilityTitle(
            isTrusted: PermissionStatus.snapshot().accessibilityTrusted
        )
    }

    private func registerPrimaryHotkey() {
        guard let hotkey else { return }
        do {
            try hotkey.register()
            primaryHotkeyLabel = "⌥Space"
            primaryHotkeyError = nil
        } catch {
            do {
                try hotkey.register(
                    keyCode: 49,
                    modifiers: UInt32(optionKey | controlKey)
                )
                primaryHotkeyLabel = "⌃⌥Space"
                primaryHotkeyError = nil
            } catch {
                primaryHotkeyError = error.localizedDescription
            }
        }
        let state = primaryHotkeyError.map { "unavailable:\($0)" } ?? primaryHotkeyLabel
        _ = try? core.dispatch(
            action: .settingsSet(key: "hotkey.primary.active", value: .string(state)),
            actor: .system
        )
    }

    private func registerWindowHotkeys() {
        windowHotkeys.removeAll()
        windowShortcutRegistrationErrors.removeAll()
        for shortcut in WindowShortcut.defaults {
            let hotkey = GlobalHotkey(id: shortcut.id)
            hotkey.onPressed = { [weak self] in
                self?.performWindowShortcut(shortcut)
            }
            do {
                try hotkey.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
                windowHotkeys.append(hotkey)
            } catch {
                let message = "\(shortcut.label) unavailable"
                windowShortcutRegistrationErrors.append(message)
                fputs("Summon: window shortcut \(message): \(error)\n", stderr)
            }
        }
        let state = windowShortcutRegistrationErrors.isEmpty
            ? "\(windowHotkeys.count)/\(WindowShortcut.defaults.count)"
            : "\(windowHotkeys.count)/\(WindowShortcut.defaults.count) unavailable:"
                + windowShortcutRegistrationErrors.joined(separator: ",")
        _ = try? core.dispatch(
            action: .settingsSet(key: "hotkey.window.active", value: .string(state)),
            actor: .system
        )
    }

    private func performWindowShortcut(_ shortcut: WindowShortcut) {
        do {
            let result = try core.dispatch(action: shortcut.action, actor: .user)
            switch result.outcome {
            case .applied:
                windowShortcutLastError = nil
            case .rejected(let reason):
                windowShortcutLastError = reason
                NSSound.beep()
            case .staged:
                windowShortcutLastError = "Window action awaited review instead of running"
                NSSound.beep()
            }
        } catch {
            windowShortcutLastError = error.localizedDescription
            NSSound.beep()
        }
        installStatusItem()
    }

    private func startAgentSocketMonitoring() {
        agentSocketLifecycle = AgentSocketLifecycleController(core: core)
        reconcileAgentSocket()
        agentSocketMonitor = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            self?.reconcileAgentSocket()
        }
    }

    private func reconcileAgentSocket() {
        guard let lifecycle = agentSocketLifecycle else { return }
        switch lifecycle.reconcile() {
        case .disabled:
            agentSocketError = nil
        case .listening:
            agentSocketError = nil
        case .failed(let message):
            if agentSocketError != message {
                fputs("Summon: agent socket unavailable: \(message)\n", stderr)
                agentSocketError = message
            }
        }
    }

    @objc func showLauncher() {
        clipboardHistory.hide()
        panel.show()
    }

    private func shouldOfferFirstRunLoginChoice() -> Bool {
        guard (try? core.settings.get(LoginItemService.settingsKey)) == nil else { return false }
        return (try? core.settings.get(loginChoicePromptedKey))?.boolValue != true
    }

    private func offerFirstRunLoginChoice() {
        let alert = NSAlert()
        alert.messageText = "Keep Summon ready at login?"
        alert.informativeText = "Summon can keep ⌥Space and local clipboard history ready after sign-in. "
            + "Clipboard history stays on this Mac. You can change this later in Preferences."
        alert.addButton(withTitle: "Keep Ready at Login")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Decide Later")
        alert.beginSheetModal(for: panel.panel) { [weak self] response in
            guard let self else { return }
            let choice: FirstRunLoginChoice
            switch response {
            case .alertFirstButtonReturn:
                choice = .keepReady
            case .alertSecondButtonReturn:
                choice = .notNow
            default:
                choice = .decideLater
            }
            if choice.marksPrompted {
                _ = try? self.core.dispatch(
                    action: .settingsSet(key: self.loginChoicePromptedKey, value: .bool(true)),
                    actor: .user
                )
            }
            if let enabled = choice.requestedEnabled {
                self.applyLoginItemChoice(enabled)
            }
            self.markFirstRunLauncherSeen()
        }
    }

    private func applyLoginItemChoice(_ enabled: Bool) {
        switch LoginItemService.applyChoice(enabled) {
        case .failed:
            showLoginItemChoiceError("Summon could not change the login item.")
        case .applied(let observedEnabled):
            do {
                _ = try core.dispatch(
                    action: .settingsSet(
                        key: LoginItemService.settingsKey,
                        value: .bool(observedEnabled)
                    ),
                    actor: .user
                )
                installStatusItem()
            } catch {
                showLoginItemChoiceError(error.localizedDescription)
            }
        }
    }

    private func markFirstRunLauncherSeen() {
        _ = try? core.dispatch(
            action: .settingsSet(
                key: LauncherStarterCatalog.firstRunSeenKey,
                value: .bool(true)
            ),
            actor: .system
        )
    }

    private func showLoginItemChoiceError(_ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Login setting not changed"
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: panel.panel)
    }

    #if SUMMON_AI
    private func makeAIIntegration(service: SummonAIService) -> LauncherAIIntegration {
        LauncherAIIntegration(
            handler: { [weak service] prompt in
                guard let service else {
                    throw ModelRungError.unavailable(.l0Packaged, "AI service was released")
                }
                let response = try await service.respond(prompt: prompt, actor: .user)
                let rung = response.rung.rawValue
                switch response.kind {
                case let .answer(text):
                    return .answer(text: text, rung: rung, egressSummary: response.egressSummary)
                case let .staged(proposalID):
                    return .staged(proposalID: proposalID, rung: rung, egressSummary: response.egressSummary)
                }
            },
            searchHandler: { [weak service] prompt, allowOnce in
                guard let service, let core = service.core else { return .unavailable }
                // SearXNG when configured/auto-discovered (any port), else the
                // keyless Wikipedia floor.
                let provider = WebSearchProviderResolver.resolve(webConfig: core.webConfig)
                guard allowOnce || service.webSearchConsentGranted() else {
                    return .needsConsent(host: provider.host.isEmpty ? "en.wikipedia.org" : provider.host)
                }
                if !core.webConfig.enabled {
                    core.webConfig.enabled = true
                    _ = try? core.persistWebConfig(actor: .user)
                }
                switch try await service.searchAndAnswer(
                    query: prompt, provider: provider, allowOnce: allowOnce, actor: .user
                ) {
                case let .answer(text, rung, sources):
                    return .answer(
                        text: text,
                        sources: sources.map { "\($0.title) — \($0.url)" },
                        rung: rung.rawValue
                    )
                case let .needsConsent(host):
                    return .needsConsent(host: host)
                case .noResults:
                    return .noResults
                case .disabled:
                    return .unavailable
                }
            },
            consentGranter: { [weak service] always in
                if always { try? service?.grantWebSearchConsentAlways() }
            },
            consentIsSticky: { [weak service] in
                service?.webSearchConsentGranted() ?? false
            }
        )
    }
    #endif

    private func open(destination: AppDestination) {
        panel.hide()
        clipboardHistory.hide()
        preferences?.window?.orderOut(nil)
        switch destination {
        case .search:
            panel.show()
        case .clipboard:
            clipboardHistory.show()
        case .help:
            panel.show(query: "?")
        case .preferencesGeneral:
            showPreferences(section: .general)
        case .preferencesSearch:
            showPreferences(section: .search)
        case .preferencesClipboard:
            showPreferences(section: .clipboard)
        case .preferencesAutomation:
            showPreferences(section: .automation)
        case .preferencesAppearance:
            showPreferences(section: .appearance)
        }
    }

    private func showPreferences(section: PreferencesSection) {
        if preferences == nil {
            preferences = PreferencesWindowController(
                core: core,
                onOpenClipboard: { [weak self] in self?.showClipboard() },
                onOpenIgnoreList: { [weak self] in self?.showClipboardIgnoreList() },
                onLoginItemChanged: { [weak self] in self?.installStatusItem() }
            )
        }
        preferences?.show(section: section)
    }

    @objc func showClipboard() {
        panel.hide()
        clipboardHistory.show()
    }

    @objc func clearClipboardHistory() {
        clipboardHistory.requestClearHistory()
    }

    @objc func showClipboardIgnoreList() {
        panel.hide()
        clipboardHistory.showIgnoreList()
    }

    @objc func showPreferencesMenu() {
        panel.hide()
        clipboardHistory.hide()
        showPreferences(section: .general)
    }

    #if SUMMON_AI
    @objc func showAIStatus() {
        guard let aiService else { return }
        Task { @MainActor in
            let rows = await aiService.ladder.status()
            let details = rows.map { row in
                let state = row.available ? "Available" : "Unavailable"
                return "\(row.id.rawValue) · \(state) · \(row.detail)"
            }
            let alert = NSAlert()
            alert.messageText = "AI status"
            alert.informativeText = details.joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    #endif

    @objc func toggleLoginItem() {
        let next = !LoginItemService.isEnabled
        _ = LoginItemService.setEnabled(next)
        _ = try? core.dispatch(
            action: .settingsSet(
                key: LoginItemService.settingsKey,
                value: .bool(LoginItemService.isEnabled)
            ),
            actor: .system
        )
        installStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pasteboard?.stopPolling()
        hotkey?.unregister()
        clipboardHotkey?.unregister()
        agentSocketMonitor?.invalidate()
        agentSocketLifecycle?.stop()
    }
}
