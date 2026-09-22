import Foundation

/// The seam between the smart-paste pipeline and a live app's fields.
///
/// The real conformer (`AccessibilityFieldTarget`, SummonUI) reads and writes the
/// target app's Accessibility tree; a fake conformer lets the applicator be
/// unit-tested with no app, no permission, and no display. The pipeline never
/// talks to Accessibility directly — only through this protocol — so the
/// orchestration (which fills to apply, how to report a rejection) is testable.
///
/// Not `Sendable`: the Accessibility conformer holds live `AXUIElement` handles
/// and must run on the main thread. The applicator below is synchronous for the
/// same reason.
public protocol SmartPasteTarget: AnyObject {
    /// The fillable fields currently visible in the target app, each with a
    /// stable id valid until the next `fields()` call on this target.
    func fields() throws -> [SmartPasteFieldDescriptor]

    /// Write `value` into the field with `id`. Returns whether the value was
    /// placed. `false` means the field would not take the value (e.g. a view
    /// that ignores an Accessibility write and no keystroke path succeeded);
    /// the caller reports it, never retries blindly. Throws only on a hard
    /// failure (permission off, field gone).
    func apply(value: String, toFieldID id: String) throws -> Bool
}

/// The result of trying to place one fill.
public struct SmartPasteFillOutcome: Sendable, Hashable, Codable {
    public let fill: SmartPasteFill
    public let applied: Bool
    /// Human-readable detail (why it did or did not land).
    public let detail: String

    public init(fill: SmartPasteFill, applied: Bool, detail: String) {
        self.fill = fill
        self.applied = applied
        self.detail = detail
    }
}

/// Applies an accepted proposal to a target, one fill at a time, collecting a
/// per-fill outcome. Headless and synchronous: the un-testable Accessibility
/// work lives entirely behind `SmartPasteTarget`.
///
/// Nothing is ever applied that the user did not accept: `acceptedFieldIDs`
/// gates every write. Passing `nil` means "the whole proposal was accepted" —
/// callers that show a per-fill review pass the explicit set instead.
public struct SmartPasteApplicator {
    public init() {}

    public func apply(
        _ proposal: SmartPasteProposal,
        acceptedFieldIDs: Set<String>? = nil,
        to target: SmartPasteTarget
    ) -> [SmartPasteFillOutcome] {
        var outcomes: [SmartPasteFillOutcome] = []
        for fill in proposal.fills {
            if let acceptedFieldIDs, !acceptedFieldIDs.contains(fill.fieldID) {
                continue // not accepted → never written, never reported as applied
            }
            do {
                let applied = try target.apply(value: fill.value, toFieldID: fill.fieldID)
                outcomes.append(
                    SmartPasteFillOutcome(
                        fill: fill,
                        applied: applied,
                        detail: applied
                            ? "written via Accessibility"
                            : "the field did not accept the value"
                    )
                )
            } catch {
                outcomes.append(
                    SmartPasteFillOutcome(
                        fill: fill,
                        applied: false,
                        detail: error.localizedDescription
                    )
                )
            }
        }
        return outcomes
    }
}
