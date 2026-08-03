import Foundation

/// Hyperkey configuration seam (caps-lock-as-hyper style).
/// Registration is OS-level (Carbon/IOKit); this models the binding for settings/export.
public struct HyperkeyConfig: Sendable, Hashable, Codable, Equatable {
    public var enabled: Bool
    /// Virtual key code for the hyper base (e.g. caps lock remap is OS-level).
    public var baseKeyCode: UInt32
    public var modifiersMask: UInt32

    public static let `default` = HyperkeyConfig(
        enabled: false,
        baseKeyCode: 57, // caps lock virtual key on many layouts
        modifiersMask: 0
    )

    public init(enabled: Bool, baseKeyCode: UInt32, modifiersMask: UInt32) {
        self.enabled = enabled
        self.baseKeyCode = baseKeyCode
        self.modifiersMask = modifiersMask
    }
}

public enum DoubleTapModifier: String, Sendable, Hashable, Codable, CaseIterable {
    case command
    case option
    case control
    case shift
}

public struct DoubleTapBinding: Sendable, Hashable, Codable, Equatable {
    public var modifier: DoubleTapModifier
    public var actionName: String
    public var enabled: Bool

    public init(modifier: DoubleTapModifier, actionName: String, enabled: Bool = true) {
        self.modifier = modifier
        self.actionName = actionName
        self.enabled = enabled
    }
}
