import Foundation

/// A global shortcut: a Carbon virtual key code plus Carbon modifier flags. SummonCore has no
/// Carbon import, so the four modifier masks are written out (they match `cmdKey`, `shiftKey`,
/// `optionKey` and `controlKey` in HIToolbox).
public struct HotkeyBinding: Equatable, Hashable, Sendable {
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & (Self.command | Self.shift | Self.option | Self.control)
    }

    /// Stored as "keyCode:modifiers", for example "49:2048" for ⌥Space.
    public init?(storage: String) {
        let parts = storage.split(separator: ":")
        guard parts.count == 2, let key = UInt32(parts[0]), let mods = UInt32(parts[1]) else { return nil }
        self.init(keyCode: key, modifiers: mods)
    }

    public var storage: String { "\(keyCode):\(modifiers)" }

    /// "⌃⌥⇧⌘K", in the order macOS menus use.
    public var label: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    /// A function key works alone; every other key needs ⌘, ⌥ or ⌃, so typing never fires it.
    public var isUsableGlobally: Bool {
        Self.functionKeys.contains(keyCode) || modifiers & (Self.command | Self.option | Self.control) != 0
    }

    static let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// US-layout names for the ANSI key codes (`kVK_*`); a key outside the table shows its code.
    static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc", 117: "Forward Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
        ]
        let letters: [(UInt32, String)] = [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"),
            (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"),
            (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
        ]
        for (code, name) in letters { names[code] = name }
        let functionOrder: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in functionOrder.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()
}

/// The app-level shortcuts a user can change in Settings.
public enum SummonShortcut: String, CaseIterable, Sendable {
    case launcher
    case clipboardHistory
    case smartPaste
    case voice

    public var title: String {
        switch self {
        case .launcher: return "Launcher"
        case .clipboardHistory: return "Clipboard history"
        case .smartPaste: return "Smart Paste"
        case .voice: return "Voice"
        }
    }

    public var settingsKey: String { "shortcut.\(rawValue)" }

    /// Voice has no key of its own by default: it holds the launcher key.
    public var defaultBinding: HotkeyBinding? {
        switch self {
        case .launcher: return HotkeyBinding(keyCode: 49, modifiers: HotkeyBinding.option)
        case .clipboardHistory: return HotkeyBinding(keyCode: 8, modifiers: HotkeyBinding.option | HotkeyBinding.shift)
        case .smartPaste: return HotkeyBinding(keyCode: 9, modifiers: HotkeyBinding.option | HotkeyBinding.command)
        case .voice: return nil
        }
    }
}

/// How the voice shortcut starts listening.
public enum VoiceShortcutMode: String, CaseIterable, Sendable {
    /// Tap the launcher shortcut to open it; keep holding it to talk (the default).
    case holdLauncher = "hold-launcher"
    /// Hold the voice shortcut to talk.
    case hold
    /// Press the voice shortcut to start, press it again to stop.
    case toggle
    case off

    public static let settingsKey = "shortcut.voice.mode"

    public var title: String {
        switch self {
        case .holdLauncher: return "Hold the launcher shortcut"
        case .hold: return "Hold its own shortcut"
        case .toggle: return "Press its own shortcut to start and stop"
        case .off: return "Off"
        }
    }

    /// Whether the mode needs a key of its own.
    public var usesOwnShortcut: Bool { self == .hold || self == .toggle }
}

/// Reads and checks the stored shortcuts. Writes go through `CoreAction.settingsSet`.
public struct ShortcutSettings: Sendable {
    public let bindings: [SummonShortcut: HotkeyBinding]
    public let voiceMode: VoiceShortcutMode

    public init(bindings: [SummonShortcut: HotkeyBinding], voiceMode: VoiceShortcutMode) {
        self.bindings = bindings
        self.voiceMode = voiceMode
    }

    /// Stored values over defaults. A stored value that does not parse falls back to the default.
    public init(read: (String) -> String?) {
        var bindings: [SummonShortcut: HotkeyBinding] = [:]
        for shortcut in SummonShortcut.allCases {
            if let stored = read(shortcut.settingsKey).flatMap(HotkeyBinding.init(storage:)) {
                bindings[shortcut] = stored
            } else if let fallback = shortcut.defaultBinding {
                bindings[shortcut] = fallback
            }
        }
        self.bindings = bindings
        self.voiceMode = read(VoiceShortcutMode.settingsKey).flatMap(VoiceShortcutMode.init(rawValue:)) ?? .holdLauncher
    }

    /// The bindings the app registers: voice only when its mode has a key of its own.
    public var active: [SummonShortcut: HotkeyBinding] {
        bindings.filter { $0.key != .voice || voiceMode.usesOwnShortcut }
    }

    /// Why `binding` cannot be used for `shortcut`, or nil when it can.
    public func problem(with binding: HotkeyBinding, for shortcut: SummonShortcut) -> String? {
        guard binding.isUsableGlobally else {
            return "\(binding.label) needs ⌘, ⌥ or ⌃ (or a function key), so typing never triggers it"
        }
        var others = active
        others[shortcut] = nil
        if shortcut == .voice { others = bindings.filter { $0.key != .voice } }
        if let clash = others.first(where: { $0.value == binding }) {
            return "\(binding.label) is already the \(clash.key.title.lowercased()) shortcut"
        }
        return nil
    }
}
