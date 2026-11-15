import AppKit
import XCTest
@testable import SummonCore
@testable import SummonUI

final class ShortcutRecorderTests: XCTestCase {
    func testModifierFlagsBecomeCarbonMasks() {
        XCTAssertEqual(ShortcutRecorderButton.carbonModifiers([.option]), HotkeyBinding.option)
        XCTAssertEqual(ShortcutRecorderButton.carbonModifiers([.command, .shift, .capsLock]),
                       HotkeyBinding.command | HotkeyBinding.shift)
    }

    func testAWindowShortcutIsRefused() {
        let leftHalf = WindowShortcut.defaults[0]
        XCTAssertNotNil(ShortcutsSettingsView.windowClash(HotkeyBinding(keyCode: leftHalf.keyCode, modifiers: leftHalf.modifiers)))
        XCTAssertNil(ShortcutsSettingsView.windowClash(HotkeyBinding(keyCode: 40, modifiers: HotkeyBinding.control)))
    }

    @MainActor
    func testRecordingSavesTheSettingAndAppliesIt() throws {
        let core = try SummonCore.inMemory()
        var applied = 0
        var suspended: [Bool] = []
        let view = ShortcutsSettingsView(core: core, host: ShortcutHost(
            apply: { applied += 1; return [:] }, suspend: { suspended.append($0) }
        ))
        let recorder = try XCTUnwrap(view.recorders[.launcher])
        recorder.onRecord?(HotkeyBinding(keyCode: 40, modifiers: HotkeyBinding.control))
        XCTAssertEqual(try core.settings.get("shortcut.launcher")?.stringValue, "40:4096")
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(recorder.title, "⌃K")
        recorder.onRecord?(HotkeyBinding(keyCode: 8, modifiers: HotkeyBinding.option | HotkeyBinding.shift))
        XCTAssertEqual(try core.settings.get("shortcut.launcher")?.stringValue, "40:4096", "a clash is not saved")
        XCTAssertEqual(view.statuses[.launcher]?.stringValue, "⌥⇧C is already the clipboard history shortcut")
        _ = suspended
    }
}

final class LauncherVoiceTests: XCTestCase {
    @MainActor
    func testVoiceTextFillsTheFieldAndListeningShowsInThePlaceholder() throws {
        let panel = LauncherPanelController(core: try SummonCore.inMemory())
        panel.setListening(true)
        XCTAssertEqual(panel.searchField.placeholderAttributedString?.string, "Listening… let go to stop")
        panel.showVoiceText("What day is the 20th November?")
        XCTAssertEqual(panel.searchField.stringValue, "What day is the 20th November?")
        panel.setListening(false)
        XCTAssertNotEqual(panel.searchField.placeholderAttributedString?.string, "Listening… let go to stop")
        panel.showVoiceProblem("Summon cannot use the microphone.")
        XCTAssertEqual(panel.footerError, "Summon cannot use the microphone.")
    }

    @MainActor
    func testTheVoiceModePopupSavesTheMode() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("voice needs macOS 26") }
        let core = try SummonCore.inMemory()
        let view = ShortcutsSettingsView(core: core, host: ShortcutHost(apply: { [:] }, suspend: { _ in }))
        let popup = try XCTUnwrap(view.voiceModePopup)
        XCTAssertEqual(popup.titleOfSelectedItem, VoiceShortcutMode.holdLauncher.title)
        XCTAssertFalse(try XCTUnwrap(view.recorders[.voice]).isEnabled, "hold-launcher needs no key of its own")
        popup.selectItem(withTitle: VoiceShortcutMode.toggle.title)
        _ = popup.target?.perform(popup.action, with: popup)
        XCTAssertEqual(try core.settings.get(VoiceShortcutMode.settingsKey)?.stringValue, "toggle")
        XCTAssertTrue(try XCTUnwrap(view.recorders[.voice]).isEnabled)
    }
}
