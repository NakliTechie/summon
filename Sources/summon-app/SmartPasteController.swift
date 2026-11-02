import AppKit
import Carbon.HIToolbox
import SummonAI
import SummonCore
import SummonUI

/// The live smart-paste flow, invoked from a global hotkey. It runs while the
/// target app is still frontmost (Summon shows no panel), reads the current
/// clipboard text, enumerates the target app's fields through Accessibility, asks
/// the router where each value belongs, and — per the 2026-09-22 decision —
/// **fills directly** (no blocking dialog), then shows a non-blocking notice at the
/// notch (a pill on screens without one) with Undo. The fill is still staged+journaled (transient amber → accepted) for
/// audit; secure fields are never written; Undo restores each field's prior value.
///
/// The router is Apple FM first (it fills the form from the copied text, every
/// value checked against that text), then verdict when its loopback daemon is up
/// (egress journaled by `CoreAuthorizedVerdictTransport`), then the deterministic
/// floor, so smart paste works with Apple Intelligence and verdict both off.
@MainActor
final class SmartPasteController {
    private let core: SummonCore
    private let router: any SmartPasteRouter
    private let notice = NotchNotice()

    init(core: SummonCore) {
        self.core = core
        let verdict = VerdictSmartPasteRouter(
            transport: CoreAuthorizedVerdictTransport(core: core),
            fallback: DeterministicSmartPasteRouter()
        )
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            self.router = AppleFMSmartPasteRouter(
                generate: { try await AppleFMFormFill.generate(sourceText: $0, fields: $1) },
                fallback: verdict
            )
            return
        }
        #endif
        self.router = verdict
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
        let span = UsageLog.span("smartpaste", [
            "app": app.bundleIdentifier ?? app.localizedName ?? "?", "sourceChars": String(text.count),
        ])
        do {
            let fields = try target.fields()
            UsageLog.record("smartpaste.fields", ["fields": fields.map(Self.usageLine).joined(separator: " | ")])
            let proposal = try await SmartPasteService().propose(
                sourceText: text, fields: fields, router: router
            )
            let labels = SmartPasteService.fieldLabels(for: fields)
            span.end([
                "by": proposal.generatedBy,
                "fills": UsageLog.smartPasteSummary(fills: proposal.fills, labels: labels, applied: nil),
            ])
            guard !proposal.isEmpty else { return }

            // Routing can take a beat (a verdict round-trip). If focus left the
            // app that was frontmost at ⌥⌘V, do NOT fill — a direct fill must
            // never land in a different app than the one you invoked it on.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                UsageLog.record("smartpaste.cancelled", ["reason": "focus changed"])
                notice.show(message: "Smart Paste cancelled — focus changed", duration: 3)
                return
            }

            // Stage (journal) then accept immediately — the target is still
            // frontmost and focused, so the AX write lands without a modal
            // stealing focus first.
            let persisted = try SmartPasteService.persisted(from: proposal)
            try core.staged.upsert(persisted)
            let outcomes = try core.acceptStagedSmartPaste(id: persisted.id, target: target, actor: .user)
            UsageLog.record("smartpaste.applied", [
                "applied": String(outcomes.filter(\.applied).count), "skipped": String(outcomes.filter { !$0.applied }.count),
                "fills": UsageLog.smartPasteSummary(
                    fills: proposal.fills, labels: labels, applied: Set(outcomes.filter(\.applied).map(\.fill.fieldID))
                ),
            ])

            presentNotice(outcomes: outcomes, fields: fields, target: target)
        } catch {
            span.fail(error)
            fputs("Summon smart paste failed: \(error.localizedDescription)\n", stderr)
        }
    }

    /// One field for the usage log: id, label, nearby text. Never a field's value.
    private static func usageLine(_ field: SmartPasteFieldDescriptor) -> String {
        var line = "\(field.id):\(field.label ?? field.placeholder ?? "-")"
        if field.context != nil { line += " [row text]" }
        if field.isSecure { line += " (secure)" }
        return line
    }

    private func presentNotice(
        outcomes: [SmartPasteFillOutcome],
        fields: [SmartPasteFieldDescriptor],
        target: SmartPasteTarget
    ) {
        let labels = SmartPasteService.fieldLabels(for: fields)
        let priorByID = Dictionary(fields.map { ($0.id, $0.currentValue ?? "") }, uniquingKeysWith: { a, _ in a })
        let applied = outcomes.filter(\.applied)
        guard !applied.isEmpty else {
            let failed = outcomes.count
            notice.show(message: failed > 0 ? "Smart Paste: no field accepted the value" : "Smart Paste: nothing to fill")
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
            self?.notice.show(message: "Undone", duration: 2)
        }
        notice.show(message: message, actionTitle: "Undo", action: undo)
    }
}
