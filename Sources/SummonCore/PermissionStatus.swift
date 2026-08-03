import Foundation
import ApplicationServices

/// OS permission surface for degraded banners (SP-27, RC-48).
public struct PermissionSnapshot: Sendable, Equatable {
    public let accessibilityTrusted: Bool
    public let fullDiskAccessLikely: Bool
    public let screenRecordingLikely: Bool

    public init(accessibilityTrusted: Bool, fullDiskAccessLikely: Bool, screenRecordingLikely: Bool) {
        self.accessibilityTrusted = accessibilityTrusted
        self.fullDiskAccessLikely = fullDiskAccessLikely
        self.screenRecordingLikely = screenRecordingLikely
    }

    public var bannerMessages: [String] {
        var msgs: [String] = []
        if !accessibilityTrusted {
            msgs.append("Accessibility is off — window layout and menu search need it.")
        }
        if !fullDiskAccessLikely {
            msgs.append("Full Disk Access may be limited — content search may miss protected paths.")
        }
        if !screenRecordingLikely {
            msgs.append("Screen Recording is off — window previews cannot render.")
        }
        return msgs
    }
}

public enum PermissionStatus {
    public static func snapshot() -> PermissionSnapshot {
        let ax = AXIsProcessTrusted()
        // FDA / Screen Recording cannot be queried portably without probing private paths;
        // optimistic true until product probe fails (v0).
        return PermissionSnapshot(
            accessibilityTrusted: ax,
            fullDiskAccessLikely: true,
            screenRecordingLikely: true
        )
    }
}
