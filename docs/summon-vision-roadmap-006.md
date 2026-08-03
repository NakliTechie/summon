# Summon — Vision & Roadmap (rev 006)

*A sovereign, native macOS launcher. Every SuperCmd-class module, no account, no
server, no telemetry, AI as a removable sidecar riding the on-device ladder.*

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

**The primary competitor is Apple.** macOS Tahoe 26 sherlocked the category:
Spotlight now ships Actions (via App Intents), auto-learned Quick Keys, four
browse modes, intelligent on-device ranking, and native clipboard history
(7-day retention). Raycast remains the venture-backed subscription leader;
SuperCmd proved the one-time-native counter-position ($19.99, Swift, 33
modules, Raycast compat shim). Summon takes the position none of them can:
**fully sovereign** — free, open source, no account anywhere in the product, no
server of ours anywhere in the loop, no telemetry at all, and AI that is
zero-setup because the ground floor is Apple's on-device model, not a hosted key.

Audience shape (standing test): people who opted out of the SaaS pitch. A
launcher is the single most intimate tool on a machine — it sees every keystroke
of intent, every clipboard entry, every filename. "Who becomes themselves using
this?" — the person who wants that intimacy to stay on their disk.

Differentiators, in order of moat depth:

1. **Agent face as architecture** — every module callable by a machine (CLI +
   local socket) over the same core the hotkey drives. No competitor has this as
   a first-class design; it makes Summon the *tool surface* for coding agents
   rather than a launcher that ships its own captive agent.
2. **Edge-First AI ladder with a packaged brain** — Summon ships its own
   pinned on-device model (Gemma 4 E2B, Apache 2.0, multimodal) as the
   universal floor: every Mac back to macOS 14 gets zero-key, multimodal AI,
   while Apple Intelligence requires macOS 26 + eligible hardware.
   Everything above the floor is detected, never configured.
3. **Sovereignty as verifiable fact** — open source, no account, no telemetry,
   AGPL. SuperCmd claims "100% local"; Summon makes it auditable.
4. **A search ladder, not a search box** — Spotlight's index as the zero-cost
   floor, own full-text index as the consented upgrade, semantic recall on
   top. Searches where Spotlight won't (invisible files, unindexed volumes —
   the ProFind/EasyFind niche our audience loves) and understands content, not
   just names (the Foxtrot posture).
5. **Two extension surfaces** — the Raycast compat shim (migration story,
   parity with SuperCmd) *and* native App Intents consumption: every modern
   Mac app's declared actions appear in Summon's bar, out-of-process, zero
   sandbox risk. Absorbing Apple's own extension mechanism is the sherlock
   defense in code form.
6. **LaunchBar's object→action grammar, revived** — select a thing, Tab, act
   on it (file → app, → person, → command). The best interaction grammar this
   category ever shipped; nobody modern copied it properly.

**The wedge, validated (Aug 2026 survey):** "On-Device Semantic AI Search" is
now a named category, and the market maintains a split Summon exists to
collapse — launchers don't do semantic (Raycast, Alfred, SuperCmd); semantic
tools don't launch (Dhito, Fenn, Filect — Filect's own copy says it
"complements Alfred or Raycast rather than replacing them"). Vector is the
only occupant of both sides and is Tahoe-only, Apple-Silicon-only, closed
source. Apple's own semantic search (Core Spotlight, "Golden Gate") is
app-adoption-gated and OS-gated. Nobody in the category is open source,
nobody has an agent face, and both Vector and Apple exclude the pre-Tahoe
fleet — which makes the macOS 14 floor a beachhead market, not a spec detail.
The pure-search wedge decays as Apple lands; the durable moats are the ones
Apple won't build: agent face, BYO ladder, unlimited retention, the shim,
auditability.

**Sherlock defense, stated plainly:** ships its brain — pinned multimodal
model on every Mac back to macOS 14, vs Apple Intelligence gated to macOS 26 +
eligible hardware · unlimited clipboard vs Tahoe's 7-day
cap · BYO-AI ladder vs Apple Intelligence only · agent face (Spotlight has
none) · Raycast shim · macOS 14 floor (Tahoe features require 26) ·
sovereignty as auditable fact, not a privacy-page claim.

Monetisation: none. Flows-from-shape rule — if anything ever monetises here it is
the relay pattern (compute-backed, zero-retention), and v1 needs no relay at all.
Subscriptions for a no-account tool = betrayal. Closed.

---

## 2. Roles (spine, per Build Doctrine — before invariants)

| Role | Authority | Scope | Ownership | Trust boundary | Attribution |
|---|---|---|---|---|---|
| **User (human)** | Everything | Global | All data; delete/export freely | Inside | Direct UI events |
| **Agent (machine)** | Any module action, opt-in, gated by developer setting; default OFF | Global once enabled | Cannot delete stores; propose-only for destructive ops | Inside once enabled | Every socket/CLI call logged to a local action journal with `actor=agent` |
| **System actor** | Clipboard watcher, auto-quit scheduler, index refresher, appcast check | Own subsystem | None | Inside | `actor=system` in journal |
| **Extension code (3rd-party, via shim)** | Only the shim API surface it declares | Its own sandbox dir + declared entitlements | Its own storage namespace | **Outside by default** — no clipboard history, no snippet store, no keychain, no socket unless the manifest declares it and the user grants it | `actor=ext:<id>` in journal |
| **AI provider (local model / user's cloud key)** | Receives only the minimum slice per invocation | Per-call context only | Nothing | Outside — data leaves only on explicit action, only to the user's own provider | Per-call record: which rung, what left the machine (knowable, per Sidecar honesty rule) |

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
4. **Sidecar removability at runtime.** Zero AI configured → every module fully
   functional. AI unavailable mid-use → clean degrade to the no-AI state, never
   an error wall.
5. **Propose, don't dispose.** Every AI output stages as an editable artifact
   (command, arrangement, event, rewrite diff) before the deterministic core
   runs it. No auto-commit, no ambient calls.
6. **One ingress.** All external data — extension manifests, appcast, clipboard
   ingestion, socket messages — passes one schema validator.
7. **One action bus.** UI, hotkey, CLI, socket, and shim all dispatch the same
   typed actions into the same core. One mechanism, N doors.
8. **Attribution.** Every action carries an actor tag into the local journal.
9. **i18n from day one.** String catalogs on every surface; no hardcoded
   user-facing strings. (Baked silently; matches SuperCmd's 10+ languages.)
10. **Latency budget.** Invoke-to-visible < 50 ms; keystroke-to-results < 16 ms
    for the local index. Native or nothing — this is why there's no Electron.
11. **Ask before big downloads.** Models and Whisper weights prompt before
    fetching; never surprise-download gigabytes.

---

## 4. Module inventory → milestones

Full SuperCmd-class inventory, sequenced by risk and dependency. One spec, one
codebase, staged deploys. `/forward-pass` between milestones in fresh context;
gate conditions machine-checkable; "done" is the verifier's word.

### M0 — Shim spike (riskiest assumption first)

Can unmodified Raycast extensions run inside a Swift process? The bet: embedded
JS runtime (JavaScriptCore first; fall back to embedded Node only if JSC +
polyfills can't carry the Node API surface real extensions use) + a custom React
reconciler mapping Raycast's component tree (`List`, `Detail`, `Form`,
`ActionPanel`) to native views.

- Scope: render + execute **3 real store extensions unmodified** (one List-based,
  one Form-based, one that calls `fetch` + local storage). Raycast-managed-auth
  extensions explicitly out of scope (same carve-out SuperCmd ships).
- Prior-art discipline: read SuperCmd's shim source (GitHub, public) and sol's
  internals before writing a line. Embrace-and-extend if license permits;
  clean-room stop-gate if GPL is involved.
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
(unlimited, SQLite; **parity bar: Maccy** — the module succeeds when Chirag
retires Maccy) · snippets + expansion · app hotkeys · hyperkey ·
double-tap modifiers · navigation bindings · system commands · settings ·
onboarding + `?` guide (generated by `/guide`).

**Gate:** unit + integration green; action-bus replay reconstructs state;
latency budget asserted in CI on Apple Silicon runner; `/walkthrough` on the
single human role.

### M2 — Power modules (v1.1)

**App Intents action surface** — enumerate and invoke every installed app's
declared actions from the bar, with Quick-Key-style abbreviations learned
locally · window management + Spaces (**parity bar: Rectangle** — the module
succeeds when Chirag retires Rectangle) · alt-tab switcher (live previews, close-with-
backspace) · screenshot + annotation (region, arrows, redaction, history, pin)
· system widgets (CPU/mem/disk/top-apps) · terminal-from-launcher · custom
scripts · browser integration (tabs/history/bookmarks, profile-aware) ·
calendar (EventKit) · quick camera · auto-quit · read-aloud (AVSpeech —
deterministic, not AI).

**Gate:** per-module fixture tests; screenshot annotations round-trip;
walkthrough re-run including agent role if M4 lands first.

### M3 — AI sidecar layer (v1.2)

The ladder (all detected, never a config screen; default assumption: new user
has nothing configured — and everything still works):

```
L0  Packaged brain — Gemma 4 E2B (Apache 2.0), quantized GGUF, hash-pinned,
    llama.cpp + Metal embedded in-process. Fetched on first consent (size +
    hash stated; mirrored on HF naklitechie org) — never bundled in the cask;
    the app download stays 20MB-class. Multimodal: screenshot-ask and
    dictation ride this same model. E4B auto-offered on ≥16GB machines
    (detected, not a picker). MTP drafter adoption is evidence-gated at C3.
L1  Apple Foundation Models — the instant, zero-download floor where hardware
    allows, and the fallback when the user declines the L0 fetch. Post-WWDC26
    this rung self-upgrades: image input (serves screenshot-ask natively),
    integrated Vision tools, and a second higher-capability on-device model
    on higher-end Macs — all absorbed by detection with zero work from us.
L2  Detected local runtime — Ollama / LM Studio via direct localhost
    (native app: no bridge needed; the bridge is a browser artifact)
L3  BYOK — user's key, Keychain-held, straight to provider
    (no relay rung: sovereign v1 ships no compute of ours)

Riding Apple's curve (post-WWDC26): our `ModelRung` seam remains the core
abstraction — it must, since the floor is macOS 14 and Apple's LanguageModel
protocol requires 26/27 — but on capable systems the seam adapts to the
LanguageModel protocol, with L0's embedded engine wrapped as a conforming
provider, so rungs ride one session API where the OS allows. The framework
open-sources summer 2026; read it, don't guess it. Core AI (macOS 27, Apple
Silicon) is a D7 watch item as a possible L0 fast-path — never the universal
engine, since it excludes the floor. **Private Cloud Compute is an explicit
non-rung**: it ships user data to Apple's servers on a rung the user never
keyed, and its free tier is App-Store-metered while Summon is brew-distributed
— declined on doctrine and mechanics both. Net position: every Apple on-device
improvement lands as a free, silent L1 upgrade, while L0 holds the floor for
the fleet Apple leaves behind.
```

Sidecars, each attached to a real surface, each with a no-AI floor:

| Sidecar | Attaches to | Artifact staged | No-AI floor |
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

**Gate:** removability harness — full M1+M2 test suite passes with AI subsystem
compiled out / disabled; ladder detection matrix tested against mocked
environments (nothing / Ollama present / key present); per-call "what left the
machine" record asserted.

### M4 — Shim productionized + completions (v1.3)

Raycast extension shim hardened from the M0 spike: manifest-declared
entitlements, per-extension sandbox + storage namespace, Raycast backup import
(settings, snippets, quicklinks, hotkeys) · sync via user-owned transport —
config/store export-import as versioned JSON + optional iCloud Drive folder
watch (their Apple account, their transport; we host nothing, read nothing;
never a relay of ours) · remaining i18n locale passes.

**Gate:** M0 harness extended to 10 store extensions; sandbox escape attempts
(fixture suite) fail loud; Raycast backup import round-trips a real backup.

### v2 horizon (inline, not separate docs)

Raycast-managed-auth extension support (if feasible without their infra) ·
voice agent surface (on-device realtime — AI-native module, exempt from
sidecar) · deliberate chat-window revisit · Linux feasibility probe (un-resourced;
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
annotator · alt-tab overlay · widgets strip · onboarding · **where each sidecar
attaches on each surface** (never a parked box) · staged-proposal pattern (the
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
| D3 | Apple Foundation Models floor | Requires macOS 26+ / Apple Intelligence-capable hardware | **Adopt as L1**; ladder degrades to L2/L3 below floor — detection handles it, not a setting |
| D4 | Sparkle vs custom updater | Sparkle (mature) / static-appcast custom | **Sparkle**, telemetry-free config, probe before commit |
| D5 | macOS floor | 14 / 15 / 26 | Propose **14**, with L1 gated by capability detection |
| D6 | Packaged model | Gemma 4 E2B / E4B tiered / Qwen3-1.7B | **E2B default, E4B auto-offered ≥16GB** — Apache 2.0, multimodal, one model for text + vision + audio |
| D7 | Embedded runtime | llama.cpp + Metal (C API, GGUF ubiquity, MTP drafters) / MLX-Swift | **llama.cpp**; probe at chunk-5 open decides with latency + memory evidence |
| D8 | S3 embedding model | EmbeddingGemma 308M (Gemma license) / Apache-licensed alternative | Probe at chunk-5 open; **license cleanliness wins ties** |

---

*Bundle status: 3 of 3 complete. State file entry for
`NAKLITECHIE-PROJECT-STATE.md`: Summon — specced (bundle rev 006), M0 = Raycast
shim spike; D1 = Summon, D5 = macOS 14 (adopted); search = full ladder S1–S3 in
v1; App Intents = M2; L0 = packaged Gemma 4 E2B (D6 adopted, D7/D8 probe at
chunk-5 open); D2/D4 resolve at C0. **Parked as separate future specs:**
(a) standalone sovereign search/actions CLI for agent workflows, (b) local-only
screen-memory semantic recall (Rewind-class, sovereign). Neither blocks Summon.*
