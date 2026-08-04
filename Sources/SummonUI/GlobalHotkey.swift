import AppKit
import Carbon
import Foundation
import SummonCore

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
    private static let sharedSignature = OSType(0x53554D4E) // 'SUMN'

    /// - Parameter id: Unique id (1 = launcher, 2 = clipboard, …).
    public init(id: UInt32 = 1, signature: OSType = OSType(0x53554D4E)) {
        self.id = id
        self.signature = signature
    }

    deinit {
        unregister()
    }

    /// `keyCode` Carbon virtual key (49 = space, 9 = V).
    public func register(keyCode: UInt32 = 49, modifiers: UInt32 = UInt32(optionKey)) throws {
        unregister()

        Self.lock.lock()
        Self.callbacks[id] = { [weak self] in
            self?.onPressed?()
        }
        try Self.installSharedHandlerIfNeeded_locked()
        Self.lock.unlock()

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
            callback = GlobalHotkey.callbacks[hkID.id]
            GlobalHotkey.lock.unlock()

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
