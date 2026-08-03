import XCTest
import SummonCore
@testable import SummonUI

/// C-spine: one action end-to-end via stub UI (actor=user).
final class StubLauncherTests: XCTestCase {
    func testStubUISetsSettingThroughBus() throws {
        let core = try SummonCore.inMemory()
        let ui = StubLauncher(core: core)

        let result = try ui.setSetting(key: "theme", value: .string("dark"))
        XCTAssertTrue(result.isApplied)
        XCTAssertEqual(try ui.getSetting("theme"), .string("dark"))

        let entries = try core.journal.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].actor, .user)
        XCTAssertEqual(entries[0].outcome, "applied")
    }

    func testStubUIAndAgentShareSameStore() throws {
        let core = try SummonCore.inMemory()
        let ui = StubLauncher(core: core)

        _ = try ui.setSetting(key: "shared", value: .string("from-ui"))
        _ = try core.dispatch(
            action: .settingsSet(key: "shared", value: .string("from-agent")),
            actor: .agent
        )

        XCTAssertEqual(try ui.getSetting("shared"), .string("from-agent"))
        let actors = try core.journal.allEntries().map(\.actor)
        XCTAssertEqual(actors, [.user, .agent])
    }
}

final class TokenContrastTests: XCTestCase {
    /// Gate §8.7: contrast ≥ 4.5:1 for text tokens on surfaces.
    func testTextOnSurfacesMeetsWCAG_AA() {
        let pairs: [(Tokens.RGBA, Tokens.RGBA, String)] = [
            (Tokens.Color.text, Tokens.Color.bgGlass, "text on bg.glass"),
            (Tokens.Color.text, Tokens.Color.surface, "text on surface"),
            (Tokens.Color.text, Tokens.Color.surfaceRaised, "text on surface.raised"),
            (Tokens.Color.textDim, Tokens.Color.bgGlass, "text.dim on bg.glass"),
            (Tokens.Color.textDim, Tokens.Color.surface, "text.dim on surface"),
        ]
        for (fg, bg, label) in pairs {
            let ratio = fg.contrastRatio(against: bg)
            XCTAssertGreaterThanOrEqual(
                ratio,
                4.5,
                "\(label): contrast \(ratio) < 4.5"
            )
        }
    }
}
