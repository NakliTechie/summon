import Foundation
import ApplicationServices

/// OS permission surface for degraded banners (SP-27, RC-48).
/// Optional fields: `nil` means not probed (do not claim granted or denied).
public struct PermissionSnapshot: Sendable, Equatable {
    public let accessibilityTrusted: Bool
    /// `nil` = not probed on this OS path.
    public let fullDiskAccess: Bool?
    /// `nil` = not probed on this OS path.
    public let screenRecording: Bool?

    public init(
        accessibilityTrusted: Bool,
        fullDiskAccess: Bool? = nil,
        screenRecording: Bool? = nil
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.fullDiskAccess = fullDiskAccess
        self.screenRecording = screenRecording
    }

    public var bannerMessages: [String] {
        var msgs: [String] = []
        if !accessibilityTrusted {
            msgs.append("Accessibility is off — window layout and menu search need it.")
        }
        if fullDiskAccess == false {
            msgs.append("Full Disk Access is off — content search may miss protected paths.")
        }
        if screenRecording == false {
            msgs.append("Screen Recording is off — window previews cannot render.")
        }
        // Unknown (nil) FDA / Screen Recording: no optimistic "ok" claim
        return msgs
    }
}

public enum PermissionStatus {
    public static func snapshot() -> PermissionSnapshot {
        let ax = AXIsProcessTrusted()
        // FDA and Screen Recording have no portable public API probe without
        // private paths or TCC side effects. Leave nil (unknown) rather than
        // hardcoding true (forward-pass SB6).
        return PermissionSnapshot(
            accessibilityTrusted: ax,
            fullDiskAccess: nil,
            screenRecording: nil
        )
    }
}
