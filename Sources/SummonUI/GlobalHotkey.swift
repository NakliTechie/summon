import AppKit
import Carbon
import Foundation
import SummonCore

/// Stable Rectangle-compatible defaults for every window layout Summon exposes.
/// Shortcut choices follow Rectangle's MIT-licensed alternate defaults
/// (Copyright 2019-2026 Ryan Hanson):
/// https://github.com/rxhanson/Rectangle/blob/main/Rectangle/WindowAction.swift
public struct WindowShortcut: Sendable, Equatable {
    public let id: UInt32
    public let layout: WindowLayout
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let label: String

    public init(id: UInt32, layout: WindowLayout, keyCode: UInt32, modifiers: UInt32, label: String) {
        self.id = id
        self.layout = layout
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    public var action: CoreAction {
        .moduleRun(
            name: "window.arrange",
            targetID: "window:\(layout.rawValue)",
            path: nil,
            payload: ["layout": .string(layout.rawValue), "gap": .number(8)]
        )
    }

    public var displayName: String {
        switch layout {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .maximize: return "Maximize"
        case .center: return "Center"
        case .leftThird: return "Left Third"
        case .centerThird: return "Center Third"
        case .rightThird: return "Right Third"
        }
    }

    public var menuTitle: String {
        "\(displayName) — \(label)"
    }

    public static let defaults: [WindowShortcut] = {
        let chord = UInt32(controlKey | optionKey)
        return [
            WindowShortcut(id: 100, layout: .leftHalf, keyCode: UInt32(kVK_LeftArrow), modifiers: chord, label: "⌃⌥←"),
            WindowShortcut(id: 101, layout: .rightHalf, keyCode: UInt32(kVK_RightArrow), modifiers: chord, label: "⌃⌥→"),
            WindowShortcut(id: 102, layout: .topHalf, keyCode: UInt32(kVK_UpArrow), modifiers: chord, label: "⌃⌥↑"),
            WindowShortcut(id: 103, layout: .bottomHalf, keyCode: UInt32(kVK_DownArrow), modifiers: chord, label: "⌃⌥↓"),
            WindowShortcut(id: 104, layout: .topLeft, keyCode: UInt32(kVK_ANSI_U), modifiers: chord, label: "⌃⌥U"),
            WindowShortcut(id: 105, layout: .topRight, keyCode: UInt32(kVK_ANSI_I), modifiers: chord, label: "⌃⌥I"),
            WindowShortcut(id: 106, layout: .bottomLeft, keyCode: UInt32(kVK_ANSI_J), modifiers: chord, label: "⌃⌥J"),
            WindowShortcut(id: 107, layout: .bottomRight, keyCode: UInt32(kVK_ANSI_K), modifiers: chord, label: "⌃⌥K"),
            WindowShortcut(id: 108, layout: .maximize, keyCode: UInt32(kVK_Return), modifiers: chord, label: "⌃⌥↩"),
            WindowShortcut(id: 109, layout: .center, keyCode: UInt32(kVK_ANSI_C), modifiers: chord, label: "⌃⌥C"),
            WindowShortcut(id: 110, layout: .leftThird, keyCode: UInt32(kVK_ANSI_D), modifiers: chord, label: "⌃⌥D"),
            WindowShortcut(id: 111, layout: .centerThird, keyCode: UInt32(kVK_ANSI_F), modifiers: chord, label: "⌃⌥F"),
            WindowShortcut(id: 112, layout: .rightThird, keyCode: UInt32(kVK_ANSI_G), modifiers: chord, label: "⌃⌥G"),
        ]
    }()

    public static var defaultSummary: String {
        defaults.map { "\($0.layout.rawValue): \($0.label)" }.joined(separator: " · ")
    }
}

/// Registers a global Carbon hotkey (⌘Space is system-owned — default is ⌥Space).
///
/// Multiple instances share one app-target event handler and dispatch by hotkey id.
/// Accessibility is not required for `RegisterEventHotKey`.
public final class GlobalHotkey: @unchecked Sendable {
    public var onPressed: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private let signature: OSType
    private let id: UInt32

    private static let lock = NSLock()
    private static var callbacks: [UInt32: () -> Void] = [:]
    private static var handlerRef: EventHandlerRef?
    /// - Parameter id: Unique id (1 = launcher, 2 = clipboard, …).
    public init(id: UInt32 = 1, signature: OSType = OSType(0x53554D4E)) {
        self.id = id
        self.signature = signature
    }

    deinit {
        unregister()
    }

    /// `keyCode` Carbon virtual key (49 = Space).
    public func register(keyCode: UInt32 = 49, modifiers: UInt32 = UInt32(optionKey)) throws {
        unregister()

        Self.lock.lock()
        do {
            defer { Self.lock.unlock() }
            Self.callbacks[id] = { [weak self] in
                self?.onPressed?()
            }
            do {
                try Self.installSharedHandlerIfNeeded_locked()
            } catch {
                Self.callbacks.removeValue(forKey: id)
                throw error
            }
        }

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let reg = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard reg == noErr else {
            Self.lock.lock()
            Self.callbacks.removeValue(forKey: id)
            Self.lock.unlock()
            throw CoreError.io("RegisterEventHotKey failed: \(reg) (key=\(keyCode) mods=\(modifiers))")
        }
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        Self.lock.lock()
        Self.callbacks.removeValue(forKey: id)
        if Self.callbacks.isEmpty, let handlerRef = Self.handlerRef {
            RemoveEventHandler(handlerRef)
            Self.handlerRef = nil
        }
        Self.lock.unlock()
    }

    private static func installSharedHandlerIfNeeded_locked() throws {
        if handlerRef != nil { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, theEvent, _ -> OSStatus in
            guard let theEvent else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(
                theEvent,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard err == noErr else { return noErr }

            let callback: (() -> Void)?
            GlobalHotkey.lock.lock()
            defer { GlobalHotkey.lock.unlock() }
            callback = GlobalHotkey.callbacks[hkID.id]

            if let callback {
                DispatchQueue.main.async {
                    callback()
                }
            }
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        guard status == noErr else {
            throw CoreError.io("InstallEventHandler failed: \(status)")
        }
    }
}
