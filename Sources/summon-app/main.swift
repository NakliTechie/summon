import AppKit
import Foundation
import SummonCore
import SummonUI

/// Menu-bar host: ⌥Space launcher, clipboard poll, agent socket (default on).
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
    var pasteboard: PasteboardService!
    var hotkey: GlobalHotkey!
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
                    pb.setString(text, forType: .string)
                }
            )
            panel = LauncherPanelController(core: core)
            pasteboard = PasteboardService(core: core)
            pasteboard.startPolling()

            hotkey = GlobalHotkey()
            hotkey.onPressed = { [weak self] in
                self?.panel.toggle()
            }
            try hotkey.register() // ⌥Space (locked 2026-08-03)

            try startAgentSocketIfEnabled()

            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = statusItem?.button {
                button.title = "∑"
                button.toolTip = "Summon \(SummonVersion.string)"
            }
            let menu = NSMenu()
            menu.addItem(NSMenuItem(
                title: "Show Launcher",
                action: #selector(showLauncher),
                keyEquivalent: ""
            ))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(
                title: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            ))
            statusItem?.menu = menu
        } catch {
            fputs("Summon failed to start: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    /// Default ON; disable with `summon settings set agent.socket.enabled false`.
    private func startAgentSocketIfEnabled() throws {
        let enabled: Bool
        if case .bool(let b) = try core.settings.get(AgentSocketServer.enabledSettingKey) {
            enabled = b
        } else {
            enabled = true
        }
        guard enabled else { return }
        let server = AgentSocketServer(core: core)
        try server.start()
        agentSocket = server
    }

    @objc func showLauncher() {
        panel.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pasteboard?.stopPolling()
        hotkey?.unregister()
        agentSocket?.stop()
    }
}
