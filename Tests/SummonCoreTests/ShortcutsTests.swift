import XCTest
@testable import SummonCore

/// Configurable shortcuts (Chirag 2026-11-15: "options for shortcut keys (configurable in settings)").
final class ShortcutsTests: XCTestCase {
    func testDefaultsAreTheShippedShortcuts() {
        let settings = ShortcutSettings { _ in nil }
        XCTAssertEqual(settings.bindings[.launcher]?.label, "⌥Space")
        XCTAssertEqual(settings.bindings[.clipboardHistory]?.label, "⌥⇧C")
        XCTAssertEqual(settings.bindings[.smartPaste]?.label, "⌥⌘V")
        XCTAssertNil(settings.bindings[.voice], "voice holds the launcher key by default")
        XCTAssertEqual(settings.voiceMode, .holdLauncher)
    }

    func testStoredValuesWinAndABadValueFallsBack() {
        let stored = ["shortcut.launcher": "40:4096", "shortcut.smartPaste": "garbage", "shortcut.voice.mode": "toggle"]
        let settings = ShortcutSettings { stored[$0] }
        XCTAssertEqual(settings.bindings[.launcher]?.label, "⌃K")
        XCTAssertEqual(settings.bindings[.smartPaste]?.label, "⌥⌘V")
        XCTAssertEqual(settings.voiceMode, .toggle)
    }

    func testStorageRoundTripsAndDropsStrayFlags() {
        let binding = HotkeyBinding(keyCode: 49, modifiers: HotkeyBinding.option | 0x10000)
        XCTAssertEqual(binding.storage, "49:2048")
        XCTAssertEqual(HotkeyBinding(storage: binding.storage), binding)
        XCTAssertNil(HotkeyBinding(storage: "49"))
    }

    func testLabelsFollowMenuOrder() {
        let all = HotkeyBinding.control | HotkeyBinding.option | HotkeyBinding.shift | HotkeyBinding.command
        XCTAssertEqual(HotkeyBinding(keyCode: 0, modifiers: all).label, "⌃⌥⇧⌘A")
        XCTAssertEqual(HotkeyBinding(keyCode: 111, modifiers: 0).label, "F12")
        XCTAssertEqual(HotkeyBinding(keyCode: 200, modifiers: HotkeyBinding.command).label, "⌘Key 200")
    }

    func testAShortcutNeedsAModifierUnlessItIsAFunctionKey() {
        let settings = ShortcutSettings { _ in nil }
        XCTAssertNotNil(settings.problem(with: HotkeyBinding(keyCode: 0, modifiers: 0), for: .launcher))
        XCTAssertNotNil(settings.problem(with: HotkeyBinding(keyCode: 0, modifiers: HotkeyBinding.shift), for: .launcher),
                        "⇧A is typing")
        XCTAssertNil(settings.problem(with: HotkeyBinding(keyCode: 111, modifiers: 0), for: .launcher), "F12 alone")
        XCTAssertNil(settings.problem(with: HotkeyBinding(keyCode: 40, modifiers: HotkeyBinding.control), for: .launcher))
    }

    func testAShortcutCannotTakeAnotherSummonShortcut() {
        let settings = ShortcutSettings { _ in nil }
        let smartPaste = HotkeyBinding(keyCode: 9, modifiers: HotkeyBinding.option | HotkeyBinding.command)
        XCTAssertEqual(settings.problem(with: smartPaste, for: .launcher), "⌥⌘V is already the smart paste shortcut")
        XCTAssertNil(settings.problem(with: smartPaste, for: .smartPaste), "its own key again is fine")
        let launcher = HotkeyBinding(keyCode: 49, modifiers: HotkeyBinding.option)
        XCTAssertNotNil(settings.problem(with: launcher, for: .voice), "voice's own key cannot be the launcher's")
    }

    func testVoiceRegistersAKeyOnlyInItsOwnKeyModes() {
        let voice = HotkeyBinding(keyCode: 9, modifiers: HotkeyBinding.control | HotkeyBinding.option)
        let holdLauncher = ShortcutSettings(bindings: [.voice: voice], voiceMode: .holdLauncher)
        XCTAssertNil(holdLauncher.active[.voice])
        let hold = ShortcutSettings(bindings: [.voice: voice], voiceMode: .hold)
        XCTAssertEqual(hold.active[.voice], voice)
    }

    func testCatalogNamesTheRegisteredShortcut() {
        defer { ShortcutCatalog.setActiveLabels([:]) }
        XCTAssertEqual(ShortcutCatalog.launcher, "⌥Space")
        ShortcutCatalog.setActiveLabels([.launcher: "⌃K"])
        XCTAssertEqual(ShortcutCatalog.launcher, "⌃K")
        XCTAssertTrue(GuideContent.lines.contains { $0.body.contains("⌃K") }, "the guide follows the setting")
    }
}
