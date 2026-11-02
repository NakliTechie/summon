import AppKit
import XCTest
@testable import SummonCore
@testable import SummonUI

/// The answer card must lay its text out where it can be seen, not only hold
/// the string: on 2026-11-02 a web answer reached the card and drew blank.
final class AIAnswerViewTests: XCTestCase {
    @MainActor
    func testAnAnswerLaysOutInsideTheCard() throws {
        let card = AIAnswerView(frame: NSRect(x: 0, y: 0, width: 640, height: 160))
        let window = NSWindow(contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        card.display(title: "Answer · apple-fm · web", answer: "You can take a direct flight from Mumbai to Paris.")
        card.frame = NSRect(x: 0, y: 0, width: 640, height: 200)
        card.layoutSubtreeIfNeeded()

        let text = card.answerText
        let manager = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        XCTAssertGreaterThan(text.frame.width, 300, "the text view spans the card")
        XCTAssertGreaterThan(used.height, 10, "the answer lays out at least one line")
        XCTAssertTrue(text.visibleRect.intersects(used.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)),
                      "the laid-out text is inside the visible area")
    }

    func testAWebAnswerIsVisibleInTheLauncher() throws {
        let answer = "Answer: You can take a direct flight from Mumbai to Paris. From Chhatrapati Shivaji "
            + "Maharaj International Airport (BOM) in Mumbai, you will fly out to Charles De Gaulle (CDG) in Paris."
        let integration = LauncherAIIntegration(
            handler: { _ in .answer(text: "x", rung: "apple-fm", egressSummary: "") },
            searchHandler: { _, _ in
                .answer(text: answer, sources: [
                    "Direct flights from Mumbai to Paris (BOM-CDG) — https://www.directflights.com/BOM-CDG",
                    "Mumbai to France - 7 ways to travel - Rome2rio — https://www.rome2rio.com/s/Mumbai/France",
                ], rung: "apple-fm")
            }
        )
        let panel = LauncherPanelController(core: try SummonCore.inMemory(), aiIntegration: integration)
        panel.show(query: "what's the route to france from Mumbai?")
        panel.runWebSearch(LauncherConfirmation(
            actionName: "web.search",
            result: SearchResult(id: "web:fixture", title: "Search the web & answer", kind: .command,
                                 payload: ["prompt": .string("what's the route to france from Mumbai?")]),
            query: "what's the route to france from Mumbai?",
            requiresUserConfirmation: false
        ))
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        let card = panel.aiAnswerView
        let text = card.answerText
        let manager = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        XCTAssertGreaterThan(text.frame.width, 300, "the text view spans the card")
        XCTAssertGreaterThan(used.height, 10, "the answer lays out")
        XCTAssertTrue(text.visibleRect.intersects(used.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)),
                      "the laid-out text is inside the visible area")
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            card.window?.appearance = NSAppearance(named: name)
            XCTAssertGreaterThan(card.inkedPixels(), 200, "the answer is drawn in \(name.rawValue)")
        }
        XCTAssertGreaterThan(Int(card.drawnState()["chars"] ?? "0") ?? 0, 100)
        panel.hide()
    }
}
