import XCTest
@testable import SummonUI

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
        for (foreground, background, label) in pairs {
            let ratio = foreground.contrastRatio(against: background)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(label): contrast \(ratio) < 4.5")
        }
    }
}
