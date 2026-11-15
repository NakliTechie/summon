import AppKit
import Foundation
import SummonCore

/// What the shortcut settings need from the app: re-register from the stored settings (returning
/// a message for each shortcut that failed), the messages from the last registration (startup
/// included, so a failure shows when Settings opens), and pause every global shortcut while one is being
/// recorded. A registered Carbon hotkey takes its keys before the window sees them, so ⌥Space
/// could not be typed into the recorder while the launcher holds it.
public struct ShortcutHost {
    public var apply: () -> [SummonShortcut: String]
    public var current: () -> [SummonShortcut: String]
    public var suspend: (Bool) -> Void
    /// The languages voice can listen in (from Apple's recognizers, which SummonUI cannot import).
    public var languages: @Sendable () async -> [VoiceLanguage.Choice]

    public init(apply: @escaping () -> [SummonShortcut: String], current: @escaping () -> [SummonShortcut: String] = { [:] },
                suspend: @escaping (Bool) -> Void, languages: @escaping @Sendable () async -> [VoiceLanguage.Choice] = { [] }) {
        self.apply = apply
        self.current = current
        self.suspend = suspend
        self.languages = languages
    }
}

/// A button that shows a shortcut and records a new one when clicked: press the keys, Esc cancels.
public final class ShortcutRecorderButton: NSButton {
    public var onRecord: ((HotkeyBinding) -> Void)?
    public var onRecordingChanged: ((Bool) -> Void)?
    public private(set) var isRecording = false
    private var monitor: Any?
    private var shownLabel = ""

    public init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func show(_ binding: HotkeyBinding?) {
        shownLabel = binding?.label ?? "None"
        if !isRecording { title = shownLabel }
        setAccessibilityLabel("Shortcut \(shownLabel). Click to record a new one.")
    }

    @objc private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        title = "Type a shortcut…"
        onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.isDisjoint(with: [.command, .option, .control, .shift]) {
                self.stopRecording()
                return nil
            }
            let binding = HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(flags))
            self.stopRecording()
            self.onRecord?(binding)
            return nil
        }
    }

    /// Ends recording without a new shortcut (Esc, a second click, or the window closing).
    public func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        title = shownLabel
        onRecordingChanged?(false)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= HotkeyBinding.command }
        if flags.contains(.shift) { mods |= HotkeyBinding.shift }
        if flags.contains(.option) { mods |= HotkeyBinding.option }
        if flags.contains(.control) { mods |= HotkeyBinding.control }
        return mods
    }
}

/// The Shortcuts rows in Settings: one per app shortcut, each with a recorder, a reset button and a
/// line that says why a shortcut was refused or could not be registered.
public final class ShortcutsSettingsView: NSStackView {
    private let core: SummonCore
    private let host: ShortcutHost
    private let shortcuts: [SummonShortcut]
    private(set) var recorders: [SummonShortcut: ShortcutRecorderButton] = [:]
    private(set) var statuses: [SummonShortcut: NSTextField] = [:]
    private(set) var voiceModePopup: NSPopUpButton?
    private(set) var voiceLanguagePopup: NSPopUpButton?

    /// Voice needs macOS 26 (Apple's on-device speech), so its row appears only there.
    public static var availableShortcuts: [SummonShortcut] {
        if #available(macOS 26.0, *) { return SummonShortcut.allCases }
        return SummonShortcut.allCases.filter { $0 != .voice }
    }

    public init(core: SummonCore, host: ShortcutHost, shortcuts: [SummonShortcut] = ShortcutsSettingsView.availableShortcuts) {
        self.core = core
        self.host = host
        self.shortcuts = shortcuts
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        for shortcut in shortcuts { addArrangedSubview(makeRow(shortcut)) }
        refresh(errors: host.current())
    }

    /// Ends any recording in progress. The Preferences window calls this as it closes, because the
    /// closed window is kept, so its views never leave it and `viewDidMoveToWindow` does not fire.
    public func stopRecording() {
        recorders.values.forEach { $0.stopRecording() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var settings: ShortcutSettings {
        ShortcutSettings { [core] key in (try? core.settings.get(key))?.stringValue }
    }

    private func makeRow(_ shortcut: SummonShortcut) -> NSView {
        let name = NSTextField(labelWithString: shortcut.title)
        name.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let recorder = ShortcutRecorderButton()
        recorder.onRecordingChanged = { [host] recording in host.suspend(recording) }
        recorder.onRecord = { [weak self] binding in self?.record(binding, for: shortcut) }
        let reset = NSButton(title: "Reset", target: nil, action: nil)
        reset.bezelStyle = .rounded
        reset.target = self
        reset.action = #selector(resetPressed(_:))
        reset.identifier = NSUserInterfaceItemIdentifier(shortcut.rawValue)
        reset.setAccessibilityLabel("Reset the \(shortcut.title.lowercased()) shortcut")
        let status = NSTextField(labelWithString: "")
        status.textColor = .systemRed
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        recorders[shortcut] = recorder
        statuses[shortcut] = status
        let row = NSStackView(views: [name, recorder, reset])
        row.spacing = 8
        var lines: [NSView] = [row]
        if shortcut == .voice {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: VoiceShortcutMode.allCases.map(\.title))
            popup.target = self
            popup.action = #selector(voiceModeChanged(_:))
            popup.setAccessibilityLabel("How voice starts")
            voiceModePopup = popup
            let indent = NSView()
            indent.widthAnchor.constraint(equalToConstant: 130).isActive = true
            let modeRow = NSStackView(views: [indent, popup])
            modeRow.spacing = 8
            lines.append(modeRow)
            lines.append(makeLanguageRow())
        }
        lines.append(status)
        let column = NSStackView(views: lines)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return column
    }

    /// "Listen in": Automatic, then every language Apple's recognizers offer, filled in when the
    /// list arrives (it is read from macOS asynchronously).
    private func makeLanguageRow() -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(voiceLanguageChanged(_:))
        popup.setAccessibilityLabel("Language voice listens in")
        voiceLanguagePopup = popup
        showLanguages([])
        let languages = host.languages
        Task { @MainActor [weak self] in
            let choices = await languages()
            self?.showLanguages(choices)
        }
        let label = NSTextField(labelWithString: "Listen in")
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let row = NSStackView(views: [label, popup])
        row.spacing = 8
        return row
    }

    func showLanguages(_ choices: [VoiceLanguage.Choice]) {
        guard let popup = voiceLanguagePopup else { return }
        let stored = (try? core.settings.get(VoiceLanguage.settingsKey))?.stringValue ?? VoiceLanguage.automatic
        var items = [VoiceLanguage.Choice(id: VoiceLanguage.automatic, name: "Automatic (this Mac's language)")]
        items += choices.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        if !items.contains(where: { $0.id == stored }) { items.append(VoiceLanguage.Choice(id: stored, name: stored)) }
        popup.removeAllItems()
        for item in items {
            popup.addItem(withTitle: item.name)
            popup.lastItem?.representedObject = item.id
        }
        popup.selectItem(at: items.firstIndex { $0.id == stored } ?? 0)
    }

    @objc private func voiceLanguageChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        let action: CoreAction = id == VoiceLanguage.automatic
            ? .settingsDelete(key: VoiceLanguage.settingsKey)
            : .settingsSet(key: VoiceLanguage.settingsKey, value: .string(id))
        if case .settingsDelete = action, (try? core.settings.get(VoiceLanguage.settingsKey)) == nil { return }
        save(action, for: .voice)
    }

    /// Shows the stored shortcuts and the messages from the last registration.
    public func refresh(errors: [SummonShortcut: String]) {
        let current = settings
        voiceModePopup?.selectItem(withTitle: current.voiceMode.title)
        recorders[.voice]?.isEnabled = current.voiceMode.usesOwnShortcut
        for shortcut in shortcuts {
            recorders[shortcut]?.show(current.bindings[shortcut])
            statuses[shortcut]?.stringValue = errors[shortcut] ?? ""
            statuses[shortcut]?.isHidden = errors[shortcut] == nil
        }
    }

    private func record(_ binding: HotkeyBinding, for shortcut: SummonShortcut) {
        if let problem = settings.problem(with: binding, for: shortcut) ?? Self.windowClash(binding) {
            refresh(errors: [shortcut: problem])
            return
        }
        save(.settingsSet(key: shortcut.settingsKey, value: .string(binding.storage)), for: shortcut)
    }

    @objc private func voiceModeChanged(_ sender: NSPopUpButton) {
        guard let mode = VoiceShortcutMode.allCases.first(where: { $0.title == sender.titleOfSelectedItem }) else { return }
        save(.settingsSet(key: VoiceShortcutMode.settingsKey, value: .string(mode.rawValue)), for: .voice)
    }

    @objc private func resetPressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let shortcut = SummonShortcut(rawValue: raw) else { return }
        guard (try? core.settings.get(shortcut.settingsKey)) != nil else { return refresh(errors: host.apply()) }
        save(.settingsDelete(key: shortcut.settingsKey), for: shortcut)
    }

    private func save(_ action: CoreAction, for shortcut: SummonShortcut) {
        do {
            if case .rejected(let reason) = try core.dispatch(action: action, actor: .user).outcome {
                // The bus words refusals for the command line ("Store error: …"); the row needs only the cause.
                let cause = reason.hasPrefix("Store error: ") ? String(reason.dropFirst("Store error: ".count)) : reason
                return refresh(errors: [shortcut: cause])
            }
            refresh(errors: host.apply())
        } catch {
            refresh(errors: [shortcut: error.localizedDescription])
        }
    }

    /// Summon's window-layout shortcuts are fixed; a new shortcut may not take one of their keys.
    static func windowClash(_ binding: HotkeyBinding) -> String? {
        WindowShortcut.defaults.first { $0.keyCode == binding.keyCode && $0.modifiers == binding.modifiers }
            .map { "\(binding.label) is the \($0.displayName.lowercased()) window shortcut" }
    }
}
