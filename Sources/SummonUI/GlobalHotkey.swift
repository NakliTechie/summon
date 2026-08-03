import AppKit
import Carbon
import Foundation
import SummonCore

/// Registers a global carbon hotkey (⌘Space is system-owned — default is ⌥Space).
/// Accessibility is not required for Carbon `RegisterEventHotKey`.
public final class GlobalHotkey: @unchecked Sendable {
    public var onPressed: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature = OSType(0x53554D4E) // 'SUMN'

    public init() {}

    deinit {
        unregister()
    }

    /// `keyCode` Carbon virtual key (49 = space). `modifiers` Carbon option/cmd/control/shift.
    public func register(keyCode: UInt32 = 49, modifiers: UInt32 = UInt32(optionKey)) throws {
        unregister()
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let this = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
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
