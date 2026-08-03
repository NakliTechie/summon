import AppKit
import Foundation
import SummonCore
import SummonUI

/// Minimal host app: menu-bar agent + ⌥Space launcher panel.
/// Not yet a full .app bundle / code-signed product — SPM executable for local run.
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
            try hotkey.register() // ⌥Space

            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = statusItem?.button {
                button.title = "∑"
                button.toolTip = "Summon \(SummonVersion.string)"
            }
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Show Launcher", action: #selector(showLauncher), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem?.menu = menu

            // Agent socket remains off by default (developer setting later).
        } catch {
            fputs("Summon failed to start: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    @objc func showLauncher() {
        panel.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pasteboard?.stopPolling()
        hotkey?.unregister()
    }
}
