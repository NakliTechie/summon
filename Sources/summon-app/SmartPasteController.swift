import AppKit
import Carbon.HIToolbox
import SummonAI
import SummonCore
import SummonUI

/// The live smart-paste flow, invoked from a global hotkey. It runs while the
/// target app is still frontmost (Summon shows no panel), reads the current
/// clipboard text, enumerates the target app's fields through Accessibility, asks
/// the router where each value belongs, and — per the 2026-09-22 decision —
/// **fills directly** (no blocking dialog), then shows a non-blocking toast with
/// Undo. The fill is still staged+journaled (transient amber → accepted) for
/// audit; secure fields are never written; Undo restores each field's prior value.
///
/// The router is verdict-first with a deterministic fallback: verdict when its
/// loopback daemon is up (egress journaled by `CoreAuthorizedVerdictTransport`),
/// the deterministic floor otherwise, so smart paste works with verdict off.
@MainActor
final class SmartPasteController {
    private let core: SummonCore
    private let router: any SmartPasteRouter
    private let toast = SmartPasteToast()

    init(core: SummonCore) {
        self.core = core
        self.router = VerdictSmartPasteRouter(
            transport: CoreAuthorizedVerdictTransport(core: core),
            fallback: DeterministicSmartPasteRouter()
        )
    }

    func run() {
        Task { await runAsync() }
    }

    private func runAsync() async {
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            )
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let target = AccessibilityFieldTarget(pid: app.processIdentifier)
        do {
            let fields = try target.fields()
            let proposal = try await SmartPasteService().propose(
                sourceText: text, fields: fields, router: router
            )
            guard !proposal.isEmpty else { return }

            // Routing can take a beat (a verdict round-trip). If focus left the
            // app that was frontmost at ⌥⌘V, do NOT fill — a direct fill must
            // never land in a different app than the one you invoked it on.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                toast.show(message: "Smart Paste cancelled — focus changed", undo: nil, duration: 3)
                return
            }

            // Stage (journal) then accept immediately — the target is still
            // frontmost and focused, so the AX write lands without a modal
            // stealing focus first.
            let persisted = try SmartPasteService.persisted(from: proposal)
            try core.staged.upsert(persisted)
            let outcomes = try core.acceptStagedSmartPaste(id: persisted.id, target: target, actor: .user)

            presentToast(outcomes: outcomes, fields: fields, target: target)
        } catch {
            fputs("Summon smart paste failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func presentToast(
        outcomes: [SmartPasteFillOutcome],
        fields: [SmartPasteFieldDescriptor],
        target: SmartPasteTarget
    ) {
        let labels = SmartPasteService.fieldLabels(for: fields)
        let priorByID = Dictionary(fields.map { ($0.id, $0.currentValue ?? "") }, uniquingKeysWith: { a, _ in a })
        let applied = outcomes.filter(\.applied)
        guard !applied.isEmpty else {
            let failed = outcomes.count
            toast.show(message: failed > 0 ? "Smart Paste: no field accepted the value" : "Smart Paste: nothing to fill", undo: nil)
            return
        }

        let names = applied.map { labels[$0.fill.fieldID] ?? $0.fill.fieldID }
        var message = "Filled " + names.joined(separator: ", ")
        let failedCount = outcomes.count - applied.count
        if failedCount > 0 { message += " · \(failedCount) skipped" }

        // Undo restores each filled field's prior value through the same target.
        let undo: () -> Void = { [weak self] in
            for outcome in applied {
                _ = try? target.apply(value: priorByID[outcome.fill.fieldID] ?? "", toFieldID: outcome.fill.fieldID)
            }
            self?.toast.show(message: "Undone", undo: nil, duration: 2)
        }
        toast.show(message: message, undo: undo)
    }
}
