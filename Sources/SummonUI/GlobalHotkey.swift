import AppKit
import Carbon
import Foundation
import SummonCore

/// Registers a global carbon hotkey (⌘Space is system-owned — default is ⌥Space).
/// Accessibility is not required for Carbon `RegisterEventHotKey`.
/// Use a unique `hotKeyID` per instance when registering multiple hotkeys.
public final class GlobalHotkey: @unchecked Sendable {
    public var onPressed: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType
    private let hotKeyID: UInt32

    /// - Parameters:
    ///   - id: Unique id within the signature (1 = launcher, 2 = clipboard, …).
    ///   - signature: Four-char code; default 'SUMN'.
    public init(id: UInt32 = 1, signature: OSType = OSType(0x53554D4E)) {
        self.hotKeyID = id
        self.signature = signature
    }

    deinit {
        unregister()
    }

    /// `keyCode` Carbon virtual key (49 = space, 9 = V). `modifiers` Carbon option/cmd/control/shift.
    public func register(keyCode: UInt32 = 49, modifiers: UInt32 = UInt32(optionKey)) throws {
        unregister()
        let hotKeyID = EventHotKeyID(signature: signature, id: hotKeyID)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData else { return noErr }
            // Only fire for our hotkey id (shared app event target).
            var hkID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            let this = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            guard hkID.id == this.hotKeyID, hkID.signature == this.signature else {
                return noErr
            }
            DispatchQueue.main.async {
                this.onPressed?()
            }
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else {
            throw CoreError.io("InstallEventHandler failed: \(status)")
        }

        let reg = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard reg == noErr else {
            throw CoreError.io("RegisterEventHotKey failed: \(reg)")
        }
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
