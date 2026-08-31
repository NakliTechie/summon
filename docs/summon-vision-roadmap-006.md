# Summon — Vision & Roadmap (rev 006)

*A sovereign, native macOS launcher. Full module surface, no account, no
server, no telemetry, with core AI capabilities riding a local model ladder.*

**Track:** Sovereign (NakliTechie) · **Price:** Free · **License:** AGPL-3.0
**Surface:** Native macOS (Swift, AppKit + SwiftUI) — deliberate Build-Doctrine
rung-2 escalation: global hotkeys, Accessibility API, clipboard, window
management, and screen capture are OS-level reach the browser is walled off from.
**Distribution:** Homebrew cask via `NakliTechie/homebrew-tap` (signed +
notarized, Developer ID); Sparkle-based updates pointed at GitHub Releases —
update checks fetch a static appcast, no analytics of ours in the loop.
**Name:** Summon (D1 closed).

---

## 1. Position

Summon is a **fully sovereign** macOS launcher: free, open source (AGPL-3.0), no
account anywhere in the product, no server of ours anywhere in the loop, no
telemetry at all. AI starts on-device when the user’s hardware and OS allow it
and stays on a local-only ladder.

A launcher is the single most intimate tool on a machine — it sees intent,
clipboard, and filenames. Summon is for people who want that intimacy to stay
on their disk.

**Product pillars (in priority order):**

1. **Agent face as architecture** — every module callable by a machine (CLI +
   local socket) over the same core the hotkey drives. Summon is a *tool surface*
   for coding agents, not a launcher that ships a captive chat agent.
2. **Core local AI ladder** — Apple Foundation Models on capable Macs, an
   already-running Ollama/LM Studio server when present, and an embedded
   llama.cpp path as the packaged fallback. No cloud model tier.
3. **Sovereignty as verifiable fact** — open source, no account, no telemetry,
   AGPL; gates assert no-model launcher degradation and network posture.
4. **A search ladder, not a search box** — system metadata index as the zero-cost
   floor, optional consented full-text, semantic recall on top. Content-aware
   where names alone fail; invisible/unindexed paths when the user opts in.
5. **Two extension surfaces** — sandboxed third-party package shim (migration
   and community packages) *and* native App Intents consumption so declared
   app actions appear in the bar out-of-process.
6. **Object→action grammar** — select a thing, Tab, act on it (file → app,
   person, command). First-class interaction, not an afterthought.

**Platform floor:** macOS 14. Newer OS features are used when present; they do
not define the minimum.

**Monetisation:** none in v1. No subscription for a no-account tool. If anything
ever monetises later, only via user-owned compute patterns with zero retention —
not a Summon cloud account.

---

## 2. Roles (spine, per Build Doctrine — before invariants)

| Role | Authority | Scope | Ownership | Trust boundary | Attribution |
|---|---|---|---|---|---|
| **User (human)** | Everything | Global | All data; delete/export freely | Inside | Direct UI events |
| **Agent (machine)** | Any module action, opt-in, gated by developer setting; default OFF | Global once enabled | Cannot delete stores; propose-only for destructive ops | Inside once enabled | Every socket/CLI call logged to a local action journal with `actor=agent` |
| **System actor** | Clipboard watcher, auto-quit scheduler, index refresher, appcast check | Own subsystem | None | Inside | `actor=system` in journal |
| **Extension code (3rd-party, via shim)** | Only the shim API surface it declares | Its own sandbox dir + declared entitlements | Its own storage namespace | **Outside by default** — no clipboard history, no snippet store, no keychain, no socket unless the manifest declares it and the user grants it | `actor=ext:<id>` in journal |
| **Model runtime (Apple Foundation Models / detected local server / embedded llama.cpp)** | Receives only the minimum slice per invocation | Per-call context only | Nothing | Local machine; process boundary varies by runtime | Per-call record: selected runtime and any network boundary crossed |

Handoff map (authority transitions): user grants extension entitlements at
install; user enables agent face in developer settings; user accepts an AI
proposal → deterministic core executes it. No transition auto-commits.

The found-absent actor: **extension code**. The shim imports untrusted
third-party JavaScript into a trusted native process. It is an actor with its own
row, its own sandbox, and the strictest boundary in the matrix — not a feature.

---

## 3. Invariants (the spine — written before the first feature)

1. **No server of ours, ever.** No account, no telemetry, no crash reporting
   phoning home, no analytics. Update check = static appcast fetch only.
2. **All stores local and exportable.** Clipboard history, snippets, quicklinks,
   settings, action journal — SQLite + JSON export. Closure lives in the
   artifact: exports replay without Summon.
3. **Keys live in macOS Keychain** (VaultMind pattern, native form). Never in
   config files, never transmitted to anything but the user's own provider.
4. **No-model degradation.** AI is core and always built. With no available
   model, deterministic launcher modules remain usable and AI surfaces degrade
   without an error wall.
5. **Propose, don't dispose.** Every AI output stages as an editable artifact
   (command, arrangement, event, rewrite diff) before the deterministic core
   runs it. No auto-commit, no ambient calls.
6. **One ingress.** All external data — extension manifests, appcast, clipboard
   ingestion, socket messages — passes one schema validator.
7. **One action bus.** UI, hotkey, CLI, socket, and shim all dispatch the same
   typed actions into the same core. One mechanism, N doors.
8. **Attribution.** Every action carries an actor tag into the local journal.
9. **i18n from day one.** String catalogs on every surface; no hardcoded
   user-facing strings. (Baked silently; multi-locale from day one where keys exist.)
10. **Latency budget.** Invoke-to-visible < 50 ms; keystroke-to-results < 16 ms
    for the local index. Native or nothing — this is why there's no Electron.
11. **Ask before big downloads.** Models and Whisper weights prompt before
    fetching; never surprise-download gigabytes.

---

## 4. Module inventory → milestones

Full module inventory, sequenced by risk and dependency. One spec, one
codebase, staged deploys. `/forward-pass` between milestones in fresh context;
gate conditions machine-checkable; "done" is the verifier's word.

### M0 — Shim spike (riskiest assumption first)

Can unmodified third-party JS launcher packages run inside a Swift process? The
bet: embedded JS runtime (JavaScriptCore first; fall back to embedded Node only
if JSC + polyfills can't carry the Node API surface real packages use) + a custom
React reconciler mapping the package component tree (`List`, `Detail`, `Form`,
`ActionPanel`) to native views.

- Scope: render + execute **3 real store packages unmodified** (one List-based,
  one Form-based, one that calls `fetch` + local storage). Vendor-managed-auth
  packages that require a third-party cloud account are out of scope for v1.
- Prior-art discipline: read public open-source shims before inventing APIs.
  Embrace-and-extend if license permits; clean-room stop-gate if GPL is involved.
- **Gate (deterministic):** scripted harness launches each of the 3 extensions
  headlessly via the action bus, asserts rendered node tree + action results
  against fixtures. Green = shim is real. Red after budget = shim moves to v2,
  M1 proceeds unchanged, tried-trail written to state file.

### M1 — Launcher core (v1.0 ship)

The spine plus the modules nothing else works without:

app/file launcher · file search as a **ladder, detected/consented like the AI
ladder**: S1 Spotlight index (`NSMetadataQuery`/mdfind, zero cost, plus a real
filter grammar — `kind:pdf modified:<7d`, the HoudahSpot posture) → S2 own
FTS5 full-text index (opt-in, disk cost stated, consent sheet before first
index — content search, unindexed volumes, invisible files) → S3 semantic
embeddings ride S2 at M3 · object→action grammar (Tab on any result) · calculator
inline · emoji picker · quicklinks · menu-item search · clipboard history
(unlimited, SQLite; text + privacy filters day-one; image/rich media required
for daily clipboard completeness) · snippets + expansion · app hotkeys ·
hyperkey · double-tap modifiers · navigation bindings · system commands ·
settings · onboarding + `?` guide (generated by `/guide`).

**Gate:** unit + integration green; action-bus replay reconstructs state;
latency budget asserted in CI on Apple Silicon runner; `/walkthrough` on the
single human role.

### M2 — Power modules (v1.1)

**App Intents action surface** — enumerate and invoke every installed app's
declared actions from the bar, with Quick-Key-style abbreviations learned
locally · window management + Spaces (snap layouts, multi-display math, global
shortcut map) · alt-tab switcher (live previews, close-with-
backspace) · screenshot + annotation (region, arrows, redaction, history, pin)
· system widgets (CPU/mem/disk/top-apps) · terminal-from-launcher · custom
scripts · browser integration (tabs/history/bookmarks, profile-aware) ·
calendar (EventKit) · quick camera · auto-quit · read-aloud (AVSpeech —
deterministic, not AI).

**Gate:** per-module fixture tests; screenshot annotations round-trip;
walkthrough re-run including agent role if M4 lands first.

### M3 — Core AI capability layer (v1.2)

The local-only ladder is detected rather than manually configured. Public rung
names and Apple-first versus detected-server-first priority remain an explicit
product decision; the adopted runtime set is:

```
Apple Foundation Models  Zero-download on-device model where hardware and OS
    support it; availability is detected at runtime.
Detected local server  Reuse an already-running Ollama or LM Studio endpoint;
    Summon never installs or launches an external inference runtime.
Embedded llama.cpp  Pinned, Metal-enabled in-process fallback behind explicit
    model-download consent, size disclosure, and artifact verification.
No cloud model tier  Summon sends no model prompts to a hosted provider.
```

The `ModelRung` seam remains the core abstraction because the platform floor is
macOS 14. Apple's APIs are adapters behind that seam on supported systems.
Private Cloud Compute is a non-rung.

AI capabilities, each attached to a real surface, each with a no-model floor:

| Capability | Attaches to | Artifact staged | No-model floor |
|---|---|---|---|
| NL → command | The launcher bar itself | The command/action, editable | Fuzzy search |
| NL → shell | Terminal module | The shell line, editable, never auto-run | Type it yourself |
| Quick Fix | Any selected text, any app | Rewrite as reviewable diff, applied on accept | Manual edit |
| Semantic search (S3) | File + clipboard search, riding the S2 FTS index | Ranked results (local embeddings, on-device) | S1/S2 keyword + filter grammar |
| Screenshot → ask | Screenshot tool | Apple Vision OCR text (deterministic) + answer | OCR alone still ships |
| NL → calendar/window | Calendar, window mgmt | The event / arrangement, staged | Manual create |
| Translate | Selection / launcher | Translation (Apple on-device first) | — (AI-native, exempt) |
| Dictation | Anywhere you type | Text (whisper.cpp / Apple Speech, on-device) | — (AI-native, exempt) |

**Deliberately absent: a chat window.** Per Sidecar Doctrine, a chat panel
parked beside the launcher is a second product wearing the tool's skin. Every AI
capability attaches to a surface. (If demand proves real, revisit in v2 as a
deliberate exit, with a reason — not drift.)

**Gate:** the AI target remains in the package graph; focused launcher and
search tests exercise the no-model state; ladder detection is tested against
mocked Apple/local/embedded availability; egress records remain asserted.

### M4 — Shim productionized + completions (v1.3)

Extension shim hardened from the M0 spike: manifest-declared
entitlements, per-extension sandbox + storage namespace, package backup import
(settings, snippets, quicklinks, hotkeys) · sync via user-owned transport —
config/store export-import as versioned JSON + optional iCloud Drive folder
watch (their Apple account, their transport; we host nothing, read nothing;
never a relay of ours) · remaining i18n locale passes.

**Gate:** M0 harness extended to 10 store extensions; sandbox escape attempts
(fixture suite) fail loud; package backup import round-trips a real backup.

### v2 horizon (inline, not separate docs)

Vendor-managed-auth extension support (if feasible without third-party infra) ·
voice agent surface (on-device realtime — AI-native module) · deliberate
chat-window revisit · Linux feasibility probe (un-resourced;
noted only).

---

## 5. Agent face (standing question, answered)

`summon` CLI + local UNIX domain socket, both dispatching the action bus. Off by
default; enabled in developer settings; every call journaled `actor=agent`.
Destructive actions (delete clipboard history, remove snippets) are propose-only
over the socket — staged for human accept, same as AI proposals. The same hooks
make every module headlessly testable, which is what M0's and M1's gates run on.
Example: `summon run window.arrange --layout=left-right`,
`summon clipboard search "invoice"`, `echo "..." | summon quickfix --tone=formal`.

---

## 6. UX/UI reference (bundle doc 3 — gate before M1 build opens)

Multi-surface product → earns the full interactive reference. Surfaces to draw:
launcher bar + results · settings · clipboard/snippet browsers · screenshot
annotator · alt-tab overlay · widgets strip · onboarding · **where each AI
capability attaches on each surface** (never a parked box) · staged-proposal pattern (the
one visual language every AI accept/edit/reject moment shares) · empty + error +
degraded-AI states · extension permission grant sheet · design tokens (house
palette on CSS-custom-property-equivalent: one asset catalog + semantic color
set from day one).

---

## 7. Open decisions

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | Name | **CLOSED: Summon** (Séance considered, rejected — fails verb test, diacritic splits display name from typed name) | — |
| D2 | JS runtime for shim | JavaScriptCore + polyfills / embedded Node | **JSC first**; M0 decides with evidence |
| D3 | Apple Foundation Models path | Requires macOS 26+ / Apple Intelligence-capable hardware | **Adopted**; capability detection handles availability |
| D4 | Sparkle vs custom updater | Sparkle (mature) / static-appcast custom | **Sparkle**, telemetry-free config, probe before commit |
| D5 | macOS floor | 14 / 15 / 26 | **Closed: 14**, with Apple Foundation Models capability-gated |
| D6 | Packaged model | Exact model and quantization | Reopen when embedded llama implementation starts; license and tool-call evidence decide |
| D7 | Embedded runtime | llama.cpp + Metal / MLX-Swift | **Closed: llama.cpp + Metal** |
| D8 | S3 embedding model | EmbeddingGemma 308M (Gemma license) / Apache-licensed alternative | Probe at chunk-5 open; **license cleanliness wins ties** |

---

*Bundle status: 3 of 3 complete. State file entry for
`NAKLITECHIE-PROJECT-STATE.md`: Summon — specced (bundle rev 006), M0 = extension
shim spike; D1 = Summon, D5 = macOS 14 (adopted); search = full ladder S1–S3 in
v1; App Intents = M2; AI is core with a local-only Apple/detected-server/embedded
runtime set; D7 = llama.cpp + Metal. **Parked as separate future specs:**
(a) standalone sovereign search/actions CLI for agent workflows, (b) local-only
screen-memory semantic recall (Rewind-class, sovereign). Neither blocks Summon.*

---

## 8. Direction addendum — 2026-08-06 (post daily-driver)

Written after the R0 daily-driver shell shipped (v0.6.x). Clarifies scope; nothing here overrides the §3 invariants.

**Shape thesis (load-bearing).** The right PC interaction is *summon → ask → out*: a global-hotkey launcher, not a resident chat surface. This re-affirms the no-chat-window invariant. Chat + a general-purpose assistant belong in a **separate companion app** (Jan-class) that talks to Summon's core over the **agent socket** (default OFF, journaled, `actor=agent`) — never by sharing the SQLite file directly. Diagram: [`assets/architecture/summon-two-app-architecture.png`](../assets/architecture/summon-two-app-architecture.png).

**Apple Foundation Models is live, not pending.** Verified 2026-08-06 on the M4 Pro gate host (macOS 26.5.2): the on-device model assets are present, and the Foundation Models framework is available. The `AppleFoundationModelRung` is wired through `SystemLanguageModel` and `LanguageModelSession`; native-session coverage remains separate from deterministic tests.

**Chunk status (corrected 2026-08-06 — the earlier over-scoping was wrong).** (A) Rich clipboard — images/RTF/HTML are already built + tested; the binary payload rides the journal, not `clipboard_items` (the "text-only" claim was a misread). This run added a `.file` kind for Finder file copies (`bec4483`); the remainder is native-session verification. (B) Latency guard — the budget is already codified and gate-enforced (`LatencyProbe`); only an optional profiling pass remains. (C) Apple Foundation Models — the adapter is wired; native runtime coverage remains.

**Decision — web search stays opt-in (2026-08-06).** The default-ON proposal was considered and rejected: it conflicts with W1 (default OFF) and the no-ambient-egress invariant, and search is SearXNG-only by design (self-hosted, no third-party leak) — so default-ON is meaningless without a default provider that would leak queries. **Resolved: retain opt-in (default OFF, W1 upheld). The remaining work is a one-click enable + a SearXNG quickstart — no default flip.**

**Search is grounding, not retrieval.** Its purpose is for the on-device model to *synthesize an answer* from results (summon → ask → answer → out) — a RAG tool, not a browser hand-off. Search uses a keyless Wikipedia floor plus an opt-in user-owned SearXNG instance for current-web grounding; **no native scraper reimplementation**. SearXNG may forward a consented query to its configured upstream engines. Detail in `plan/pending.md`.

**Companion app + GP-assistant** extend the already-parked "sovereign search/actions CLI" future spec above. Separate repo when the launcher is done.
