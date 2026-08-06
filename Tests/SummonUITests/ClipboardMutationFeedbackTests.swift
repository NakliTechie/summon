import AppKit
import XCTest
import SummonCore
@testable import SummonUI

final class ClipboardMutationFeedbackTests: XCTestCase {
    func testCommandDeleteRemovesSelectionWhenSearchFieldIsEmpty() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "delete-from-default-focus",
                text: "delete me",
                sourceApp: "Test",
                createdAt: Date(),
                pinned: false
            ),
            actor: .user
        )
        let controller = ClipboardHistoryController(core: core)
        controller.show()
        pumpMainRunLoop()
        defer { controller.hide() }

        let delete = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.panel.windowNumber,
            context: nil,
            characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}",
            isARepeat: false,
            keyCode: 51
        ))
        XCTAssertNil(controller.handleFocusedKey(delete))
        XCTAssertTrue(try core.clipboard.metadataPage(perBucketLimit: 5).isEmpty)
    }

    func testClipboardFooterExposesClearAndDedicatedShortcuts() throws {
        let controller = ClipboardHistoryController(core: try SummonCore.inMemory())
        let labels = descendants(of: controller.panel.contentView)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        let buttons = descendants(of: controller.panel.contentView)
            .compactMap { ($0 as? NSButton)?.title }

        XCTAssertTrue(labels.contains { $0.contains("\(ShortcutCatalog.clearClipboardHistory) Clear") })
        XCTAssertTrue(labels.contains { $0.contains("\(ShortcutCatalog.clipboardHistory) Open") })
        XCTAssertTrue(buttons.contains("Ignored Apps…"))
    }

    func testCommandDigitQuickSelectGuardsRangeAndModifier() throws {
        let core = try SummonCore.inMemory()
        _ = try core.dispatch(
            action: .clipboardIngest(
                id: "qc-only", text: "only", sourceApp: "Test", createdAt: Date(), pinned: false
            ),
            actor: .user
        )
        let controller = ClipboardHistoryController(core: core)
        controller.show()
        pumpMainRunLoop()
        defer { controller.hide() }
        func digit(_ d: String, _ code: UInt16, command: Bool) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: command ? .command : [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: controller.panel.windowNumber, context: nil,
                characters: d, charactersIgnoringModifiers: d, isARepeat: false, keyCode: code
            ))
        }
        // ⌘9 with a single item: consumed no-op, no crash (index guard).
        XCTAssertNil(controller.handleFocusedKey(try digit("9", 25, command: true)))
        // Plain "1" (no command) passes through so search typing still works.
        XCTAssertNotNil(controller.handleFocusedKey(try digit("1", 18, command: false)))
    }

    func testAppliedMutationHasNoFailureDetail() {
        let detail = ClipboardActionFeedback.failureDetail(
            label: "Delete",
            failureContext: "update the local store"
        ) {
            ActionResult(envelopeID: UUID(), outcome: .applied)
        }

        XCTAssertNil(detail)
    }

    func testRejectedMutationReportsReason() {
        let detail = ClipboardActionFeedback.failureDetail(
            label: "Delete",
            failureContext: "update the local store"
        ) {
            ActionResult(envelopeID: UUID(), outcome: .rejected(reason: "database busy"))
        }

        XCTAssertEqual(detail, "Delete could not update the local store: database busy")
    }

    func testStagedMutationDoesNotReportApplied() {
        let detail = ClipboardActionFeedback.failureDetail(
            label: "Pin",
            failureContext: "update the local store"
        ) {
            ActionResult(envelopeID: UUID(), outcome: .staged(proposalID: "proposal"))
        }

        XCTAssertEqual(detail, "Pin was staged for approval instead of being applied.")
    }

    func testThrownMutationReportsStoreFailure() {
        let detail = ClipboardActionFeedback.failureDetail(
            label: "Delete",
            failureContext: "update the local store"
        ) {
            throw CoreError.store("disk unavailable")
        }

        XCTAssertEqual(detail, "Delete could not update the local store: Store error: disk unavailable")
    }

    func testCopyFailuresReportPasteboardRecoveryForEveryContentKind() throws {
        for item in [
            ClipboardItem(id: "text", text: "Text"),
            ClipboardItem(
                id: "rich",
                text: "Rich",
                contentKind: .richText,
                flavor: "public.html",
                data: Data("<b>Rich</b>".utf8)
            ),
            ClipboardItem(
                id: "image",
                text: "",
                contentKind: .image,
                flavor: "public.png",
                data: Data([1, 2, 3])
            ),
        ] {
            let core = try SummonCore.inMemory(executor: FailingClipboardExecutor())
            let action: CoreAction = item.contentKind == .plainText
                ? .clipboardIngest(
                    id: item.id,
                    text: item.text,
                    sourceApp: nil,
                    createdAt: item.createdAt,
                    pinned: false
                )
                : .clipboardIngestRich(
                    id: item.id,
                    text: item.text,
                    sourceApp: nil,
                    createdAt: item.createdAt,
                    pinned: false,
                    contentKind: item.contentKind,
                    flavor: try XCTUnwrap(item.flavor),
                    data: try XCTUnwrap(item.data)
                )
            XCTAssertTrue(try core.dispatch(action: action, actor: .system).isApplied)
            let result = try XCTUnwrap(core.clipboard.search(
                query: FilterQuery(freeText: item.displayText, filters: []),
                limit: 5
            ).first)

            let detail = ClipboardActionFeedback.failureDetail(
                label: "Copy Clipboard Item",
                failureContext: "write to the pasteboard"
            ) {
                try core.invoke(actionName: "clipboard.copy", result: result, actor: .user)
            }

            XCTAssertEqual(
                detail,
                "Copy Clipboard Item could not write to the pasteboard: I/O error: injected writer failure"
            )
        }
    }

    private func descendants(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { descendants(of: $0) }
    }

    private func pumpMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
}

private struct FailingClipboardExecutor: ModuleExecuting {
    func open(pathOrURL: String) throws {}
    func reveal(path: String) throws {}
    func copyToPasteboard(text: String) throws {
        throw CoreError.io("injected writer failure")
    }
    func copyClipboardItem(_ item: ClipboardItem, asPlainText: Bool) throws {
        throw CoreError.io("injected writer failure")
    }
}
