import AppKit
import Carbon.HIToolbox
import SummonAI
import SummonCore
import SummonUI

/// The live smart-paste flow, invoked from a global hotkey. It runs while the
/// target app is still frontmost (Summon shows no panel first), reads the current
/// clipboard text, enumerates the target app's fields through Accessibility, asks
/// the router where each value belongs, stages the proposal (amber), and — only
/// on explicit accept in a confirmation — writes the fills back through
/// Accessibility. Nothing is ever filled without that accept.
///
/// The router is verdict-first with a deterministic fallback: verdict when its
/// loopback daemon is up (egress journaled by `CoreAuthorizedVerdictTransport`),
/// the deterministic floor otherwise, so smart paste works with verdict off.
@MainActor
final class SmartPasteController {
    private let core: SummonCore
    private let router: any SmartPasteRouter

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
            let persisted = try SmartPasteService.persisted(from: proposal)
            try core.staged.upsert(persisted)
            presentReview(
                id: persisted.id,
                proposal: proposal,
                fields: fields,
                appName: app.localizedName ?? "the frontmost app",
                target: target
            )
        } catch {
            fputs("Summon smart paste failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func presentReview(
        id: String,
        proposal: SmartPasteProposal,
        fields: [SmartPasteFieldDescriptor],
        appName: String,
        target: SmartPasteTarget
    ) {
        let labels = SmartPasteService.fieldLabels(for: fields)
        let lines = proposal.fills.map { fill -> String in
            let fieldLabel = labels[fill.fieldID] ?? fill.fieldID
            let conf = String(format: "%.2f", fill.confidence)
            return "• \(fill.value) → \(fieldLabel)  (\(fill.confidenceKind.rawValue) \(conf))"
        }

        let alert = NSAlert()
        alert.messageText = "Smart Paste into \(appName)?"
        alert.informativeText = (["Summon proposes these fills. Nothing is written until you confirm."]
            + lines).joined(separator: "\n")
        alert.addButton(withTitle: "Fill")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                let outcomes = try core.acceptStagedSmartPaste(id: id, target: target, actor: .user)
                let failed = outcomes.filter { !$0.applied }
                if !failed.isEmpty {
                    fputs("Summon smart paste: \(failed.count) field(s) did not accept the value\n", stderr)
                }
            } catch {
                fputs("Summon smart paste accept failed: \(error.localizedDescription)\n", stderr)
            }
        } else {
            try? core.rejectStagedSmartPaste(id: id, actor: .user)
        }
    }
}
