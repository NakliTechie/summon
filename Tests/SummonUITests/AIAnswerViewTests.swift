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

    /// The live panel showed the text view at width 0 with the text laid out
    /// and nothing drawn (usage log, 2026-11-02 20:54 IST). Layout must repair it.
    @MainActor
    func testLayoutRepairsAZeroWidthTextView() throws {
        let card = AIAnswerView(frame: NSRect(x: 0, y: 0, width: 648, height: 253))
        let window = NSWindow(contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        card.layoutSubtreeIfNeeded()
        card.answerText.setFrameSize(NSSize(width: 0, height: 215))
        card.display(title: "Answer · apple-fm · web", answer: String(repeating: "You can take a direct flight. ", count: 20))
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(card.answerText.frame.width, 300, "the text view spans the card")
        XCTAssertGreaterThan(card.answerInkedPixels(), 200, "the answer is drawn")
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
            XCTAssertGreaterThan(card.answerInkedPixels(), 200, "the answer is drawn in \(name.rawValue)")
        }
        XCTAssertGreaterThan(Int(card.drawnState()["chars"] ?? "0") ?? 0, 100)
        panel.hide()
    }

    /// Sources show as quiet rows (title, dim site, accent ›) that open on click;
    /// Copy and Insert keep the plain "title — url" lines.
    @MainActor
    func testSourcesShowAsRowsAndCopyKeepsTheURLs() throws {
        let card = AIAnswerView(frame: NSRect(x: 0, y: 0, width: 648, height: 253))
        let window = NSWindow(contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        card.display(title: "Answer", answer: "Fly.", sources: [
            "Cheap flights from Japan to France | Skyscanner — https://www.skyscanner.co.in/routes/jp/fr/japan-to-france.html",
            "Japan to France - 7 ways to travel — https://www.rome2rio.com/s/Japan/France",
        ])
        card.layoutSubtreeIfNeeded()

        let shown = card.answerText.string
        XCTAssertTrue(shown.contains("Cheap flights from Japan to France | Skyscanner  skyscanner.co.in ›"), shown)
        XCTAssertFalse(shown.contains("https://"), "the row shows the site, not the raw URL")
        XCTAssertTrue(card.answer.contains("· Japan to France - 7 ways to travel — https://www.rome2rio.com/s/Japan/France"))
        XCTAssertTrue(card.answer.contains("Sources:"))
        let storage = try XCTUnwrap(card.answerText.textStorage)
        let index = (shown as NSString).range(of: "rome2rio.com").location
        XCTAssertEqual(
            storage.attribute(AnswerTextView.sourceURL, at: index, effectiveRange: nil) as? String,
            "https://www.rome2rio.com/s/Japan/France"
        )
        XCTAssertNil(AIAnswerView.parse("No url here"))
    }
}
