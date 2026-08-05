import XCTest
import SummonCore
@testable import SummonUI

final class ClipboardMutationFeedbackTests: XCTestCase {
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
