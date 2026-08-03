# CLAUDE.md — Summon

Native macOS launcher, sovereign track (NakliTechie). Swift Package Manager workspace. This file routes an agent to the source of truth; it does not restate it.

## Source of truth — read before writing a line

The spec bundle lives in [`/docs`](docs/) and is authoritative. Read all three:

- [`docs/summon-vision-roadmap-006.md`](docs/summon-vision-roadmap-006.md) — vision, position, roles, **invariants**, module inventory → milestones (M0–M4), the AI ladder, open decisions (D1–D8).
- [`docs/summon-agent-handoff-006.md`](docs/summon-agent-handoff-006.md) — how the build runs: repo/build/deploy, design tokens, persistence rules, security posture, the **gate suite** (`make verify`), the continuous-run chunk plan, park walls, standing interrupts, hard rules.
- [`docs/summon-ux-reference-006.html`](docs/summon-ux-reference-006.html) — the drawn product. **Build against it, not against prose.**

## Operating rules (from the handoff — non-negotiable)

- **"Done" is the verifier's word.** `make verify` green in a fresh checker context — never a self-report. All progress reports in ATTEST-100 blocks with evidence marks.
- **No new doc files beyond the bundle.** Operational state lives in [`NAKLITECHIE-PROJECT-STATE.md`](NAKLITECHIE-PROJECT-STATE.md) — written at every checkpoint and park-wall event. (Local `plan/` is gitignored scratch, not a committed doc.)
- **Continuous run.** Chunks → checkpoints → park walls. Checkpoint green = proceed immediately. No milestone stops.
- **The only three stops** (handoff §10): locked-decision conflict · new dependency beyond the allow-list (GRDB, Sparkle, llama.cpp pinned+Metal, SwiftLint; whisper.cpp only on evidence) · genuine product-changing scope ambiguity. Everything else: decide, journal it in the state file, proceed.
- **Hard rules** (handoff §12): no Electron/WebView/React for the app itself · no telemetry of any kind · no account/server/license check · no auto-executing AI output (stage it, `staged` amber state, explicit accept) · no ambient AI calls · no chat window (v1 locked) · secrets only in Keychain · never install/require/auto-launch an external inference runtime.

## Layout

SPM targets: `SummonCore` (action bus, stores, index — zero AppKit, headless-testable) · `SummonUI` (AppKit/SwiftUI) · `SummonShim` (JS runtime + reconciler) · `SummonAI` (ladder + sidecars — **compiled out via build flag for the removability gate**) · `summon-cli`.

Build: `xcodebuild` via `Makefile` wrappers — `make build`, `make test`, `make verify` (full gate), `make release`.

## Current position

**C1-core green** (filter grammar · S1 · object→action · apps/calc/snippets). Full M1 inventory residual. Next: continue M1 modules / AppKit launcher panel → full C1. See [`NAKLITECHIE-PROJECT-STATE.md`](NAKLITECHIE-PROJECT-STATE.md).

