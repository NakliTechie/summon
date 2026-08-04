# Summon — Agent Handoff (rev 006)

*Read with `summon-vision-roadmap-006.md`. That doc owns vision, roles,
invariants, and milestone scope; this doc owns how the build runs. The UX/UI
reference (`summon-ux-reference-006.html`) is the drawn product — build against
it, not against prose.*

**Adopted defaults (overridable by Chirag only):** D1 name = **Summon** ·
D5 macOS floor = **14.0** (L1 AI rung capability-gated at runtime). D2 (JSC vs
embedded Node) and D4 (Sparkle) resolve with evidence at checkpoint C0.

---

## 1. Repo · build · deploy

- Repo: `naklitechie/summon` (GitHub, public, AGPL-3.0). `CLAUDE.md` +
  `AGENTS.md` at root per convention; this bundle lives in `/docs`.
- Layout: Swift Package Manager workspace. Targets: `SummonCore` (action bus,
  stores, index — zero AppKit imports, headless-testable), `SummonUI`
  (AppKit/SwiftUI), `SummonShim` (JS runtime + reconciler), `SummonAI`
  (ladder + sidecars — **compiled out via build flag for the removability
  gate**), `summon-cli`.
- Build: `xcodebuild` via `Makefile` wrappers: `make build`, `make test`,
  `make verify` (the full gate suite), `make release` (archive, sign,
  notarize, staple, zip, appcast entry).
- Signing: Developer ID Application cert; notarization via `notarytool`.
  **Park wall** until credentials arrive — see §9.
- Deploy: GitHub Releases + static Sparkle appcast in the repo (Pages).
  Cask PR to `naklitechie/homebrew-tap`. Version string visible in the
  launcher footer and `summon --version`, bumped before every release.
- CI: GitHub Actions on Apple Silicon runner; `make verify` is the merge gate.

## 2. Platform floor

macOS 14.0+. Apple Foundation Models rung requires newer OS + Apple
Intelligence hardware — **detect at runtime**, never a build split and never a
settings toggle. Below the floor for L1, the ladder starts at L2. Universal
binary (arm64 + x86_64); latency budget asserted on arm64 only.

## 3. Design tokens + icons

Single source: asset catalog + one `Tokens.swift` with semantic names. From the
UX reference:

- `bg.glass #14151A` · `surface #1C1E26` · `surface.raised #24262F` ·
  `text #E8E6DF` · `text.dim #9A98A0` · `accent #7C6FE8` (sigil violet) ·
  `staged #E5A54B` (**reserved exclusively for propose-don't-dispose states —
  never decorative**) · `ok #5FB37A` · `danger #E06C5F` · `hairline #33353F`.
- Type: system SF for UI; SF Mono for commands, shell lines, and anything the
  deterministic core will execute verbatim.
- Icons: SF Symbols only. No custom icon fonts, no bundled PNG icon sets.
- Vibrancy/material: `NSVisualEffectView` HUD material for the launcher panel;
  respect Reduce Transparency by falling back to solid `bg.glass`.

## 4. Empty · error · degraded UX

- Every list surface ships a designed empty state (invitation to act, per the
  UX reference — never a blank pane).
- Errors state what happened and the next action, in interface voice. Never a
  raw NSError, never an apology.
- **Degraded-AI is a designed state, not an error**: AI rung unavailable → the
  sidecar affordance dims with a one-line status ("On-device model
  unavailable — search still works"), the deterministic floor keeps working,
  nothing modal appears. This state is in the UX reference; build it exactly.
- Model/weight downloads: explicit consent sheet with size before any fetch.
  L0 weights: fetched from the HF `naklitechie` mirror, **verified against the
  pinned hash before load — mismatch fails loud, never falls back silently**;
  stored under `.../Summon/Models/`, rebuildable, excluded from exports
  (derived data). Declining L0 is a first-class path: ladder rides L1+.
  **Residency policy:** weights lazy-load (mmap) on first sidecar invocation
  and unload after an idle TTL — automatic, never a setting; the launcher's
  own footprint stays lean when AI is idle. **Intel honesty:**
  where CPU-only inference misses the sidecar latency floor, detection ranks
  that machine L2/L3-first with L0 available-but-not-default — per the
  Edge-First honesty rule, decided silently per machine. The engine is
  embedded in-process (no daemon); Summon never installs, requires, or
  launches Ollama or any external runtime on the user's behalf — L2 rides
  what already exists, nothing more.
- S2 full-text index: consent sheet before first build (estimated disk cost
  stated, scoped folders shown, one-tap disable + delete-index). The index is
  a local SQLite FTS5 store under the app container, rebuildable, excluded
  from exports (derived data, not user data).

## 5. Persistence rules

**Allowed:** SQLite (GRDB or raw) under
`~/Library/Application Support/Summon/` for clipboard history, snippets,
quicklinks, action journal, index metadata; `UserDefaults` for lightweight
prefs; macOS Keychain for every secret (BYOK keys, nothing else qualifies as a
secret store); per-extension namespaced storage under
`.../Summon/Extensions/<id>/` only.

**Forbidden:** secrets in files or UserDefaults · any write outside the app
container except user-initiated exports · iCloud key-value or CloudKit (sync is
file-based via the user's own iCloud Drive folder, watched — we never touch
CloudKit APIs that imply our container) · any network persistence · analytics
stores of any kind.

Every store has a JSON export and a documented schema (closure lives in the
artifact). Schema version stamped in every export.

## 6. Security posture

- No telemetry, no crash reporter phoning home, no analytics — verifiable by
  the network test in §8.
- One ingress: `SchemaGate` validates every external payload — extension
  manifests, appcast XML, socket messages, imported backups, clipboard
  ingestion metadata — before it reaches the bus.
- Shim sandbox: extension JS runs in its own JSC context per extension; API
  surface is allow-listed from the manifest's declared entitlements; no
  filesystem, keychain, socket, clipboard-history, or snippet access unless
  declared **and** user-granted at install (permission sheet in UX reference).
  Entitlement grants journaled.
- Agent socket: UNIX domain socket at `.../Summon/summon.sock`, mode 0600,
  off by default; destructive actions propose-only (staged for human accept).
- Hardened runtime on; entitlements minimal; Accessibility and Screen
  Recording permissions requested only when the owning module first activates,
  with an explanation sheet — never at first launch wholesale.

## 7. A11y verification

VoiceOver labels on every actionable element (the launcher list is a proper
`NSAccessibility` list, results announced with position); full keyboard
operability is definitional; Reduce Motion honored (no result-list animation);
Reduce Transparency honored (§3); contrast ≥ 4.5:1 for text tokens (asserted
in a token unit test). `/walkthrough` runs once with VoiceOver enabled.

## 8. Gate suite (`make verify` — machine-checkable, human-free)

1. Unit + integration green across targets.
2. **Replay**: action journal replayed into a fresh core reconstructs store
   state byte-equal (spine invariant 7/8).
3. **Latency**: scripted invoke-to-visible < 50 ms, keystroke-to-results
   < 16 ms on the CI arm64 runner, p95 over 100 runs.
4. **Removability**: full suite minus `SummonAI` (build flag) — everything
   green with the AI target absent.
5. **Sovereignty/network**: instrumented run of the full walkthrough script
   asserts the only egress is the appcast fetch (and user-invoked AI calls in
   AI-enabled runs, each matched to a journal record of what left).
6. **Shim fixtures**: the C0 harness — 3 (later 10) unmodified store
   extensions execute headlessly, rendered trees + action results match
   fixtures; sandbox-escape fixture suite fails loud.
7. Lint (SwiftLint strict) + token contrast test + i18n completeness check
   (no unlocalized user-facing string literals).

"Done" is `make verify` green in a fresh checker context — never the maker's
self-report.

## 9. Continuous-run plan

No milestone stops. Chunks → checkpoints → park walls. Checkpoint green =
proceed immediately to the next chunk. Milestone names (M0–M4) from the vision
doc are **labels on checkpoints only**.

| Chunk | Contents | Checkpoint (deterministic) |
|---|---|---|
| 1 | Spine: action bus, SchemaGate, stores, journal, `summon-cli` skeleton | **C-spine**: replay test + one action end-to-end via CLI and via a stub UI |
| 2 | Shim spike (JSC + reconciler, 3 extensions) | **C0**: shim fixture harness green — or budget/no-progress exit → shim parked with tried-trail, chunks renumber, nothing else moves |
| 3 | Launcher core modules (M1 list), search S1 (Spotlight index + filter grammar) + object→action grammar | **C1**: gate suite §8.1–5 + filter-grammar fixture parse tests |
| 4 | Power modules (M2 list), App Intents surface, search S2 (FTS5 index, consent sheet, invisible/unindexed coverage) | **C2**: per-module fixtures + annotator round-trip + App Intents enumeration fixture + S2 index/rebuild round-trip on a fixture corpus |
| 5 | **Opens with D7/D8 probe** (llama.cpp-Metal vs MLX-Swift on the pinned E2B quant: latency, memory, multimodal paths — evidence written to state file, decision journaled) · AI ladder L0–L3 + sidecars (M3 list), search S3 (embeddings over S2) | **C3**: removability (S1/S2 fully green with `SummonAI` compiled out) + both ladder-detection matrices + egress assertions + **golden sidecar fixtures against the hash-pinned L0 quant** (NL→command and screenshot-ask outputs graded by deterministic checks — parseable action, schema-valid — not string equality) |
| 6 | Shim productionized, package import, sync, i18n passes (M4 list) | **C4**: 10-extension harness + sandbox suite + backup round-trip |
| 7 | `/walkthrough` all roles (human, agent-via-socket, extension), `/guide` generation, release dry-run | **C5**: walkthrough log clean + `make release` produces an installable artifact |

`/forward-pass` in fresh context after every chunk; the fix-list closes before
the next chunk opens. No-progress exit: same failure 3× consecutive → write
tried-trail to `NAKLITECHIE-PROJECT-STATE.md`, escalate. Per-chunk budget cap
is the second exit.

**Park walls** (external dependencies — build against a stand-in behind a seam,
swap real on arrival, re-verify):

- **Signing credentials** (Developer ID + notary keys): build ad-hoc-signed
  until arrival; release chunk parks at `READY-signing.md` — *unblocked by:
  App Store Connect API key + Developer ID cert in CI secrets.*
- **Apple Foundation Models on CI**: runner may lack Apple Intelligence; L1
  tests run against a `FakeModelRung` behind the ladder seam; real-rung pass
  re-verified on capable hardware — `READY-l1-hardware.md`.
- **Homebrew tap cask**: templated and tested with a local tap until the first
  notarized release exists — `READY-cask.md`.

## 10. Standing interrupts (the only three stops)

1. Locked-decision conflict (doctrine, invariants list, adopted defaults).
2. New dependency beyond: GRDB, Sparkle, llama.cpp (pinned commit, Metal),
   SwiftLint. whisper.cpp only if the L0 model's audio path misses the
   dictation quality floor — evidence at chunk 5, not assumption. (Anti-NIH
   still applies — propose the mature OSS candidate at the interrupt, don't
   hand-roll.)
3. Genuine scope ambiguity that changes the product (e.g., an extension API the
   shim cannot honor without violating the sandbox row — that's a product
   call, not an engineering call).

Everything else: decide, journal the decision in the state file, proceed.

## 11. Module reference implementations — embrace-and-extend, don't reinvent

Two modules should learn from mature MIT-licensed OSS (license-compatible with
this AGPL codebase). Read their source before writing these modules; port the
hard-won logic with attribution headers rather than rediscovering edge cases:

- **Clipboard history.** Keyboard-only flow, pinning, paste-as-plain-text,
  per-app and per-pattern ignore lists, and — **non-negotiable privacy
  invariant** — honoring `org.nspasteboard.ConcealedType` and transient
  pasteboard types so password managers' copies are never stored. Image/rich
  media history is a product requirement (text path ships first). A history
  that captures passwords fails the walkthrough regardless of features.
- **Window management.** Snap calculation and display-edge math
  (halves/thirds/corners, gaps, multi-display coordinate quirks) and a stable
  default global shortcut map.

Personal acceptance: Chirag daily-drives the module for a week without needing a
separate utility for that job. Machine gates prove correctness; daily use proves
the shape.

## 12. What NOT to do — hard rules

- No Electron, no WebView launcher panel, no React for the app itself (the
  shim's reconciler is the sole JS/React surface, contained in `SummonShim`).
- No telemetry, analytics, crash reporting, or "anonymous usage stats" — not
  even opt-in.
- No account, sign-in, license check, or server of ours anywhere.
- No auto-executing AI output: nothing the model produces runs, sends, or
  commits without staging (`staged` amber state) and explicit accept.
- No ambient/background AI calls; invocation is always an explicit action.
- No chat window (v1 locked; revisit is a Chirag-only decision).
- No engine picker / provider dropdown as primary UX — ladder is detected;
  the only visible controls are the elevation offer and BYOK entry.
- No CloudKit, no relay, no hosted sync.
- Never install, require, or auto-launch an external inference runtime
  (Ollama, LM Studio, or any daemon) on the user's behalf — detect and ride
  only.
- The `ModelRung` seam is ours and universal (macOS 14 floor); Apple's
  LanguageModel protocol is an *adapter* behind it on 26/27+, never the core
  abstraction. PCC is a non-rung — no code path may route content to it.
- No secrets outside Keychain; no keys in logs or journals.
- No surprise downloads; no un-consented model fetches.
- No parallel write paths around the action bus (imports, sync, and shim all
  dispatch bus actions — orchestrate the engine).
- No new doc files beyond this bundle; state lives in
  `NAKLITECHIE-PROJECT-STATE.md`.

## 13. README scope

User-facing only: what it does, brew install line, permissions it will ask for
and why, the sovereignty statement (no account / no server / no telemetry, and
what "local" means per rung — the Sidecar honesty rule, stated plainly),
Extension migration note, agent-face quickstart, screenshot. No architecture
essays, no model names, no line counts.

## 14. Portfolio integration

After first release: portfolio + profile entry with a plain what-it-does-for-
a-user description; `NAKLITECHIE-PROJECT-STATE.md` updated at every checkpoint
and park-wall event (this is the resumability spine — every run writes it).

## 15. ATTEST-100

All agent progress reports in ATTEST-100 blocks: claims carry evidence marks;
"done" is exclusively the verifier's word (`make verify` output attached);
self-reports are claims, not proofs.
