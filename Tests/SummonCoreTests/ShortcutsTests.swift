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

    /// Codex review of b239fac: `summon settings set shortcut.launcher '0:512'` stored ⇧A, which
    /// the recorder refuses, so typing a capital A would have opened the launcher after a restart.
    func testEveryWritePathRefusesAShortcutTheRecorderRefuses() throws {
        let core = try SummonCore.inMemory()
        func outcome(_ key: String, _ value: String) throws -> ActionResult.Outcome {
            try core.dispatch(action: .settingsSet(key: key, value: .string(value)), actor: .user).outcome
        }
        for (key, value) in [("shortcut.launcher", "0:512"), ("shortcut.launcher", "space"),
                             ("shortcut.launcher", "123:6144"), ("shortcut.voice.mode", "shout")] {
            guard case .rejected = try outcome(key, value) else { return XCTFail("\(key)=\(value) was stored") }
        }
        XCTAssertNil(try core.settings.get("shortcut.launcher"))
        XCTAssertEqual(try outcome("shortcut.launcher", "40:4096"), .applied)
        XCTAssertEqual(try outcome("shortcut.voice.mode", "toggle"), .applied)
        XCTAssertEqual(try core.settings.get("shortcut.launcher")?.stringValue, "40:4096")
        XCTAssertNil(ShortcutSettings.refusal(key: "search.defaultAction", value: .string("open")))
    }

    /// Codex review of 5dc12af: checking clashes on each write rejected a valid import, because the
    /// import writes the clipboard key (⌥Space) before the launcher key (⌃K) that frees it.
    func testAnImportThatSwapsShortcutsIsAccepted() throws {
        let source = try SummonCore.inMemory()
        _ = try source.dispatch(action: .settingsSet(key: "shortcut.launcher", value: .string("40:4096")), actor: .user)
        _ = try source.dispatch(action: .settingsSet(key: "shortcut.clipboardHistory", value: .string("49:2048")), actor: .user)
        let target = try SummonCore.inMemory()
        try DataExport.importJSON(try DataExport.export(core: source), into: target)
        XCTAssertEqual(try target.settings.get("shortcut.launcher")?.stringValue, "40:4096")
        XCTAssertEqual(try target.settings.get("shortcut.clipboardHistory")?.stringValue, "49:2048")
    }

    func testAStoredWindowLayoutKeyFallsBack() {
        let settings = ShortcutSettings { $0 == "shortcut.smartPaste" ? "123:6144" : nil }
        XCTAssertEqual(settings.bindings[.smartPaste], SummonShortcut.smartPaste.defaultBinding)
    }

    func testAStoredShortcutThatTypingWouldTriggerFallsBack() {
        let settings = ShortcutSettings { $0 == "shortcut.launcher" ? "0:512" : nil }
        XCTAssertEqual(settings.bindings[.launcher], SummonShortcut.launcher.defaultBinding)
    }

    /// A core made without a container removes its own consent folder; about 9,200 had piled up.
    func testAnInMemoryCoreRemovesItsTemporaryFolder() throws {
        var folder: URL?
        try autoreleasepool {
            let core = try SummonCore.inMemory()
            folder = core.ftsConsentContainer
            XCTAssertTrue(FileManager.default.fileExists(atPath: core.ftsConsentContainer.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(folder).path))
    }
}
