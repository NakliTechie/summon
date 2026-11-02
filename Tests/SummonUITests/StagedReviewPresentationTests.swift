import XCTest
import AppKit
@testable import SummonCore
@testable import SummonUI

final class StagedReviewPresentationTests: XCTestCase {
    func testAgentPresentationContainsTheFullAction() throws {
        let suffix = String(repeating: "x", count: 3_000)
        let action = CoreAction.quicklinkUpsert(
            id: "long-link",
            name: "Documentation",
            url: "https://example.com/\(suffix)",
            keyword: "docs"
        )
        let compact = String(data: try JSONEncoder().encode(action), encoding: .utf8)!
        let proposal = PersistedStagedProposal(
            id: "proposal",
            rung: "agent",
            prompt: "review",
            output: compact
        )

        let presentation = try StagedReviewPresentation(proposal: proposal)
        XCTAssertTrue(presentation.reviewedText.contains(suffix))
        XCTAssertEqual(
            try SchemaGate().decodeReviewedAction(from: Data(presentation.reviewedText.utf8)),
            action
        )
    }

    func testAIReviewPreservesFullOutput() throws {
        let output = String(repeating: "line\n", count: 2_000)
        let proposal = PersistedStagedProposal(rung: "local", prompt: "rewrite", output: output)
        XCTAssertEqual(try StagedReviewPresentation(proposal: proposal).reviewedText, output)
    }

    func testTerminalFooterKeepsChromeVisible() {
        for message in ["Accepted", "Rejected", "Apply failed: reason", "Reject failed: reason"] {
            XCTAssertTrue(
                StagedReviewPresentation.showsChrome(
                    false,
                    false,
                    message
                )
            )
        }
        XCTAssertFalse(
            StagedReviewPresentation.showsChrome(
                false,
                false,
                nil
            )
        )
    }

    func testStagedCardRendersExactRunHintAndAmberBorder() throws {
        let view = StagedReviewView(frame: NSRect(x: 0, y: 0, width: 640, height: 148))
        view.display(title: "Staged", reviewedText: "exact")
        view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(view.layer?.borderWidth ?? 0, 2)
        XCTAssertNotNil(view.layer?.borderColor)
        XCTAssertTrue(descendants(of: view)
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .contains("Runs exactly this text"))
    }

    /// 2026-11-02 (live panel): the action box drew empty (text view width 0) and
    /// the buttons read "Acc…" and "Rej…". Both are checked at the real band width.
    @MainActor
    func testStagedCardDrawsItsTextAndFitsItsButtons() throws {
        let view = StagedReviewView(frame: NSRect(x: 0, y: 0, width: 648, height: 148))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        view.editor.setFrameSize(NSSize(width: 0, height: 86))
        view.display(title: "Staged (agent) — edit the exact action before accepting",
                     reviewedText: "{\"action\":\"trash.empty\",\"actor\":\"agent\"}")
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(view.editor.frame.width, 300, "the action box spans the card")
        let manager = try XCTUnwrap(view.editor.layoutManager)
        let container = try XCTUnwrap(view.editor.textContainer)
        manager.ensureLayout(for: container)
        XCTAssertGreaterThan(manager.usedRect(for: container).width, 100, "the action text is laid out in the editor")
        XCTAssertGreaterThan(container.size.width, 300, "its container spans the card")
        for button in [view.acceptButton, view.rejectButton] {
            XCTAssertGreaterThanOrEqual(button.frame.width, button.fittingSize.width, "\(button.title) fits its button")
        }
    }

    func testLauncherFooterIncludesCanonicalVersion() throws {
        let controller = LauncherPanelController(core: try SummonCore.inMemory())
        controller.show(query: "version fixture")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        defer { controller.hide() }

        XCTAssertTrue(descendants(of: controller.panel.contentView)
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .contains { $0.contains("v\(SummonVersion.string)") })
    }

    private func descendants(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { descendants(of: $0) }
    }
}
