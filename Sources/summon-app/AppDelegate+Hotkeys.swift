import AppKit
import Carbon
import Foundation
import SummonCore
import SummonUI

/// App shortcuts come from Settings (`shortcut.<name>`, defaults ⌥Space, ⌥⇧C, ⌥⌘V). Changing one
/// in Preferences re-registers them all, and each failure is reported back to its row.
extension AppDelegate {
    var shortcutSettings: ShortcutSettings {
        ShortcutSettings { [core] key in (try? core?.settings.get(key))?.stringValue }
    }

    /// Creates the hotkey objects once; `registerAppShortcuts` binds their keys.
    func installAppShortcuts() {
        hotkey = GlobalHotkey(id: 1)
        hotkey?.onPressed = { [weak self] in self?.launcherPressed() }
        hotkey?.onReleased = { [weak self] in self?.launcherReleased() }
        voiceHotkey = GlobalHotkey(id: 4)
        voiceHotkey?.onPressed = { [weak self] in self?.voiceKeyPressed() }
        voiceHotkey?.onReleased = { [weak self] in self?.voiceKeyReleased() }
        clipboardHotkey = GlobalHotkey(id: 2)
        clipboardHotkey?.onPressed = { [weak self] in
            self?.panel.hide()
            self?.clipboardHistory.toggle()
        }
        smartPasteHotkey = GlobalHotkey(id: 3)
        smartPasteHotkey?.onPressed = { [weak self] in
            // GlobalHotkey calls back on the main queue.
            MainActor.assumeIsolated { self?.smartPasteController.run() }
        }
        registerAppShortcuts()
    }

    /// Registers every app shortcut from Settings and returns a message for each one that failed.
    /// The launcher falls back to ⌃⌥Space only when it is on its default and ⌥Space is taken, so
    /// the menu-bar fallback is not the only way in.
    @discardableResult
    func registerAppShortcuts() -> [SummonShortcut: String] {
        let settings = shortcutSettings
        var errors: [SummonShortcut: String] = [:]
        var notes: [SummonShortcut: String] = [:]
        var labels: [SummonShortcut: String] = [:]
        var taken: [HotkeyBinding: SummonShortcut] = [:]
        let pairs: [(SummonShortcut, GlobalHotkey?)] = [(.launcher, hotkey), (.clipboardHistory, clipboardHotkey),
                                                        (.smartPaste, smartPasteHotkey), (.voice, voiceHotkey)]
        // Release every old key first: a swap (launcher ⇄ clipboard) would otherwise find the
        // other shortcut's old key still held and fail.
        for (_, key) in pairs { key?.unregister() }
        for (shortcut, key) in pairs {
            guard let key else { continue }
            guard let binding = settings.active[shortcut], shortcut != .voice || voiceSupported else {
                key.unregister()
                if shortcut == .voice, settings.voiceMode.usesOwnShortcut, voiceSupported {
                    errors[shortcut] = "Record a shortcut for voice, or pick \"\(VoiceShortcutMode.holdLauncher.title)\""
                }
                continue
            }
            // Two Summon shortcuts on one key (set from the command line, an import or a reset): the
            // first in this order keeps it and the other row says why it is off.
            if let owner = taken[binding] {
                key.unregister()
                errors[shortcut] = "\(binding.label) is already the \(owner.title.lowercased()) shortcut"
                continue
            }
            do {
                try key.register(keyCode: binding.keyCode, modifiers: binding.modifiers, exclusive: true)
                taken[binding] = shortcut
                labels[shortcut] = binding.label
            } catch {
                let fallback = HotkeyBinding(keyCode: 49, modifiers: HotkeyBinding.option | HotkeyBinding.control)
                if shortcut == .launcher, binding == shortcut.defaultBinding,
                   (try? key.register(keyCode: fallback.keyCode, modifiers: fallback.modifiers, exclusive: true)) != nil {
                    labels[shortcut] = fallback.label
                    taken[fallback] = shortcut
                    notes[shortcut] = "Another app uses \(binding.label), so Summon uses \(fallback.label)"
                    continue
                }
                errors[shortcut] = "\(binding.label) could not be registered: \(error.localizedDescription)"
                fputs("Summon: \(shortcut.title) shortcut \(binding.label) not registered: \(error)\n", stderr)
            }
        }
        ShortcutCatalog.setActiveLabels(labels)
        primaryHotkeyLabel = labels[.launcher] ?? settings.bindings[.launcher]?.label ?? "none"
        primaryHotkeyError = errors[.launcher]
        let failed = errors.keys.map(\.rawValue).sorted().joined(separator: " ")
        errors.merge(notes) { error, _ in error }
        shortcutErrors = errors
        let state = primaryHotkeyError.map { "unavailable:\($0)" } ?? primaryHotkeyLabel
        _ = try? core.dispatch(action: .settingsSet(key: "hotkey.primary.active", value: .string(state)), actor: .system)
        UsageLog.record("shortcuts.registered", [
            "active": labels.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "),
            "failed": failed,
        ])
        if statusItem != nil { installStatusItem() } // the menu names the launcher shortcut
        return errors
    }

    /// While a shortcut is being recorded every global shortcut is off, so its keys reach the recorder.
    /// A held shortcut's release never arrives once it is unregistered, so voice stops first.
    func suspendAppShortcuts(_ suspended: Bool) {
        if suspended {
            holdToTalkWork?.cancel()
            holdToTalkWork = nil
            launcherTapHides = false
            stopVoice()
            for key in [hotkey, clipboardHotkey, smartPasteHotkey, voiceHotkey] { key?.unregister() }
            windowHotkeys.forEach { $0.unregister() }
        } else {
            registerAppShortcuts()
            registerWindowHotkeys()
        }
    }

    var shortcutHost: ShortcutHost {
        ShortcutHost(
            apply: { [weak self] in self?.registerAppShortcuts() ?? [:] },
            current: { [weak self] in self?.shortcutErrors ?? [:] },
            suspend: { [weak self] suspended in self?.suspendAppShortcuts(suspended) }
        )
    }
}
