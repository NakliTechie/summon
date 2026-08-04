import AppKit
import Carbon
import Foundation
import SummonCore
import SummonUI

/// Menu-bar host: ⌥Space launcher, ⌥⇧V clipboard history, resident pasteboard capture, login item.
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var core: SummonCore!
    var panel: LauncherPanelController!
    var clipboardHistory: ClipboardHistoryController!
    var pasteboard: PasteboardService!
    var hotkey: GlobalHotkey!
    var clipboardHotkey: GlobalHotkey!
    var agentSocket: AgentSocketServer?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            core = try SummonCore()
            core.enableLiveSpotlight()
            core.setExecutor(
                ProcessModuleExecutor { text in
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.declareTypes([.string], owner: nil)
                    pb.setString(text, forType: .string)
                }
            )

            // CB-2: open at login default ON.
            LoginItemService.applyDefaultIfNeeded(settings: core.settings)

            panel = LauncherPanelController(core: core)
            clipboardHistory = ClipboardHistoryController(core: core)

            // CB-1: resident capture for process lifetime (panel need not be open).
            pasteboard = PasteboardService(core: core)
            pasteboard.startPolling()

            hotkey = GlobalHotkey(id: 1)
            hotkey.onPressed = { [weak self] in
                self?.clipboardHistory.hide()
                self?.panel.toggle()
            }
            try hotkey.register() // ⌥Space

            // CB-3: dedicated history — ⌥⇧V (Option+Shift+V).
            clipboardHotkey = GlobalHotkey(id: 2)
            clipboardHotkey.onPressed = { [weak self] in
                self?.panel.hide()
                self?.clipboardHistory.toggle()
            }
            try clipboardHotkey.register(
                keyCode: 9, // V
                modifiers: UInt32(optionKey | shiftKey)
            )

            try startAgentSocketIfEnabled()
            installStatusItem()
        } catch {
            fputs("Summon failed to start: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        menu.addItem(NSMenuItem(
            title: "Show Launcher",
            action: #selector(showLauncher),
            keyEquivalent: ""
        ))
        let clipItem = NSMenuItem(
            title: "Clipboard History",
            action: #selector(showClipboard),
            keyEquivalent: "v"
        )
        clipItem.keyEquivalentModifierMask = [.option, .shift]
        menu.addItem(clipItem)
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

    private func startAgentSocketIfEnabled() throws {
        let enabled: Bool
        if case .bool(let b) = try core.settings.get(AgentSocketServer.enabledSettingKey) {
            enabled = b
        } else {
            enabled = false
        }
        guard enabled else { return }
        let server = AgentSocketServer(core: core)
        try server.start()
        agentSocket = server
    }

    @objc func showLauncher() {
        clipboardHistory.hide()
        panel.show()
    }

    @objc func showClipboard() {
        panel.hide()
        clipboardHistory.show()
    }

    @objc func toggleLoginItem() {
        let next = !LoginItemService.isEnabled
        _ = LoginItemService.setEnabled(next)
        try? core.settings.set(LoginItemService.settingsKey, value: .bool(next))
        installStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pasteboard?.stopPolling()
        hotkey?.unregister()
        clipboardHotkey?.unregister()
        agentSocket?.stop()
    }
}
