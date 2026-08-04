import AppKit

/// Borderless floating panels return `canBecomeKey == false` by default, so
/// text fields never receive typing. Spotlight-style launchers must override.
public final class KeyablePanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}
