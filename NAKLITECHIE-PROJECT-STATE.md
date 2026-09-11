# NAKLITECHIE-PROJECT-STATE — Summon

## Status

**2026-09-12** — **0.7.0** released: the web-search backend lifecycle after `/harden-nt` (record: `plan/harden-2026-09-10.md`, 3 rounds, 9 isolated agents, 41-path map grown to 52):

- Every claim the surface makes about the app-owned SearXNG container is verified before it is said: live port binding + journaled loopback health probe before "restored at"; a search uses the recorded backend only while it is running on that port right now; fallback answers name the failed provider.
- Ownership by evidence, not by name: the recorded URL written by Summon's own setup gates enable / disable / remove; another profile sees `owned=no` and is refused. Found the hard way — two isolated runs (an agent's, then `make cli-e2e`'s) deleted the live container mid-test.
- `$HOME` is honored for both the recorded URL and the default store; unknown flags rejected; `web remove|status` added; paused / crash-looping / unpublished states named; `searxng-up.sh` unpauses instead of recreating, uses plain `docker run`, resolves create races; volumes removed with the container; help text fixed.
- Subprocess runner: termination-handler completion, bounded drain, kill escalation — a launch-time reconcile had parked ten minutes in `waitUntilExit` (sampled) after a `docker start` hung against a squatted port.
- Black-box seam: `SUMMON_TOOL_DIRS` + `scripts/fake-docker` let `make cli-e2e` drive the lifecycle without a daemon, and keep it from ever touching the developer's real runtime.
- 13 hardening commits, each check proven red by reintroducing its defect before green. `make verify`: 484 tests, 10 live-gated skips, 0 failures; lint 0 / 183. Live control pairs on Docker 29.4.3 green (paused, squatter, kill/restore, foreign profile, volumes, concurrent create). Not exercised live: Apple `container` runtime (not installed on this host), daemon-down paths.

**2026-09-10** — SearXNG lifecycle hardening, from the `apple/container` Discussion #2223 community reply:

- `searxng-up.sh` now follows inspect → reuse if healthy → start if stopped → recreate only after a failed start or `SUMMON_SEARXNG_RECREATE=1`, on both runtimes; a stale recorded URL or a transient health failure no longer deletes the container. Failure prints the runtime's last 40 log lines and leaves the container for inspection.
- `WebSearchBackend` (SummonCore): runtime-agnostic inspect/reconcile/stop/remove over the one app-owned container by name. Bounded recovery (3 attempts, 2 s/5 s backoff, cancellable). Never `container system stop`; Docker Desktop never launched; the Apple runtime is booted only when a recorded URL proves Summon's own setup ran.
- App: `WebSearchLifecycleController` reconciles the persisted preference with the observed backend at launch and on toggle; Preferences → Search gains a backend status row and "Remove local backend…" (confirmed, image purge opt-in). CLI: `web enable` restores, `web disable` stops and keeps data, `web remove [--purge-image]`, `web status`; agent actor stays staged.
- `WebSearchInstaller` failure reasons carry the script's output tail; `SubprocessRunner` drains its pipe concurrently and takes an optional timeout.
- `make verify`: 461 tests, 10 live-gated skips, 0 failures; SwiftLint 0 violations / 182 files; shellcheck clean on both scripts. 21 new `WebSearchBackendTests`, 1 new installer test.
- Not exercised live: Apple `container` is not installed on this host (Docker only). Stop → relaunch → restored and remove → not set up remain for the gate host.

**2026-08-31** — AI-core truth and Apple-outreach cleanup on `main`:

- Removed the phantom `SUMMON_AI_ENABLED` contract and dead executable compile branches; `SummonAI` is an unconditional app/CLI dependency.
- Added `make no-model-launcher` to exercise degraded launcher copy, fetched-link fallback, and the always-core package graph.
- Reconciled README, agent instructions, the three-file spec bundle, source comments, and current ladder state with the 2026-08-09 AI-core/local-only decision.
- Removed the unused cloud/BYOK rung case; retained the serialized `L0`/`L1`/`L2` names and current priority until a separate decision settles migration and order.
- Corrected public web-search language: explicit opt-in may install Apple `container` through Homebrew; loopback SearXNG may forward queries to configured upstream engines.
- `make verify`: 439 tests, 10 skipped live-gated tests, 0 failures; SwiftLint 178 files, 0 violations; no-model, extension omission, walkthrough, network sovereignty, version consistency, and hard latency stages passed.
- Prepared channel-specific `apple/container` and Foundation Models posts outside the repository; publication follows the pushed cleanup.

**2026-08-06** — Post daily-driver session on `main` (@ `4b236e4`):

- Brand: sigil mark shipped (flowing cyan "S" + gem on teal-black squircle); SVG masters + macOS iconset/`.icns` + menu-bar template + size set in `assets/brand/sigil`; app icon wired into `build-app.sh` + `Info.plist`; new build installed and running (`⌥⇧C` + sigil icon; installed binary SHA matches the build)
- Native guide: the 2026-08-05 checklist turned into task-based `GuideContent` entries (clipboard controls, Clear History, ignored apps, window layouts, CJK, resident/relaunch/Quit)
- Native creation: launcher-inline `Create snippet…`/`Create quicklink…` (`CreateActionCatalog` + `LauncherPanelController+Create`); CLI retained as fallback
- External purge: resolved as a phantom — 47 walkthrough fixtures purged via the journaled CLI (actor=user); 50 real clips intact; the isolation seam had already stopped new pollution
- Direction: two-app north star — Summon stays the fast launcher (no chat); chat + a GP-assistant live in a separate companion app over the agent socket. Diagram in `assets/architecture/`; vision doc §8 addendum
- Apple Foundation Models (L1): verified available now on the M4 gate host (macOS 26.5.2, 3B/2-bit) — a wiring task, not a wait
- Search: reframed as RAG grounding for on-device synthesis (Foundation Models Tool protocol, query-only egress); opt-in provider ladder (BYO-key RAG API default · user SearXNG alt); stays default OFF
- `make verify` green across the session

**2026-08-05** — Daily-driver shell on `main` (v0.6.x):

- Compact launcher (⌥Space): collapsed until type; dismiss on resign key
- Clipboard: resident image/HTML/RTF/text capture, explicit first-run login choice, dedicated history **⌥⇧C**
- Clipboard privacy checkpoint: 500 unpinned cap, delete/clear/dedupe journal scrubbing, 0700 container, 0600 database
- Clipboard controls: Clear History and editable app-name/bundle-ID ignore list
- Clipboard correctness: self-write suppression, reuse-to-top, unpin, filter reset, explicit mutation errors, dual-source ignore matching
- Rich clipboard correctness: privacy-before-read, 25 MiB cap, flavor-preserving copy, payload-hash dedupe, bounded intake, metadata pages, lazy thumbnails, and replay-stable redaction
- Search: app ranking/symlink fixes, emoji seed, app icons, calc crash fix
- Launcher correctness: stale-work cancellation, marked-text key handling, off-main effects, destructive confirmation metadata, and truthful module rows
- Search filters: unknown colon tokens stay text; live Spotlight results apply modified-date bounds
- Broad Spotlight output drains concurrently and retains a bounded first-result prefix
- Recents and aliases retain invocation paths and payloads
- Hotkey dispatcher fixed for multi-hotkey
- Primary and fallback launcher hotkeys preserve a resident status-item fallback
- Focused-window layouts use the primary-display AX origin and a 13-action ⌃⌥ shortcut map on the active Space
- Agent socket and CLI faces are default OFF, same-UID scoped, live-revocable, actor-journaled, sensitive-read gated, and propose-only for elevated actions
- Extension registry, manifest, grant, and JSC paths remain development seams; R1 executables expose no extension surface
- Store mutation journaling, import/export, FTS consent, replay recovery, and app/CLI contention use atomic and bounded paths
- The empty launcher exposes five routable starters plus persisted recents and favorites
- Preferences route to five task groups; fixture App Intents, Calendar, and menu-item search remain hidden from production
- The experimental packaged-model seam uses immutable official revisions, full artifact digests, exact-model consent, quarantine, and bounded user-managed MLX/Hugging Face processes
- The native launcher offers explicit AI staging on missed natural-language queries, retains edit/accept/reject review, and exposes ladder availability through AI Status
- `make verify` requires the full suite, no-model launcher checks, CLI e2e, lint, extension omission, walkthrough, network sovereignty, version consistency, and hard latency
- Brand concept v1 uses the sigil-violet portal-and-spark direction; application asset integration remains open

**Not** notarized / public cask yet. **Phase H** (Dev ID) remains last.

## No-progress escalations

### 2026-08-05 — external purge handoff

- Failure: Chunk 1 requires purge predicates, execution time, before/after counts, non-target survivor proof, and explicit ownership transfer.
- Tried: I searched project-local handoff artifacts across three resumed goal turns; no purge result existed.
- Tried: I inspected the recent task registry twice; no separate Summon purge task existed.
- Tried: I preserved the real store and gathered only no-store native-host facts.
- Unblock: provide the purge handoff, transfer ownership for read-only verification, or waive Chunk 1 evidence.
- **Resolved 2026-08-06:** phantom — no external owner existed. The target was walkthrough fixtures (16 `WT` quicklinks + 16 `wt` snippets + 15 `summon-cli` clips, all timestamped pre-isolation ≤2026-08-04), not the recorded `hello-cspine`/`Example`/`cspine.cli` predicates. User authorized a read-only inspection; 47 fixtures purged via the journaled CLI; the 50 real clips were preserved. Chunks 1 & 3 were never truly blocked.

## Roadmap honesty

- [~] Earlier security batches established seams. Residual verifier: close the AI, extension-runtime, and native chunks with their named live gates.
- [~] R0 image/rich clipboard code paths have automated coverage. Residual verifier: real-Mac screenshot, rapid-copy, target-app paste, broad RTF, rendered-error, and VoiceOver walkthrough.
- [ ] Phase H notarization, public cask, and Developer ID remain a stop-line requiring explicit approval.

Inventory: local `plan/pending.md` · `plan/workplan.md` (gitignored).

## Decisions

| When | Decision |
|---|---|
| 2026-08-09 | **AI is core, not a removable sidecar** — drop the sidecar/removability framing. Target **Apple Silicon (M)** only. Provider ladder: **Tier 0 = Apple Foundation Models** (default on M); **Tier 1 = local model** — reuse a running **Ollama/LM Studio** if the user serves one (localhost/network, OpenAI-compatible), else **our own embedded llama.cpp** (pinned + Metal, allow-listed). **No cloud/external provider.** Supersedes D7=MLX and the "on-device AI as a removable sidecar" posture. |
| 2026-08-09 | Web-search enable = **one-consent installer** (`WebSearchInstaller`): reuse installed Docker, else `brew install container`, then pull SearXNG and turn it on — one background step, no two-step. **Amends** the "Summon never installs a runtime" self-rule → installs Apple `container` on explicit user opt-in only (a package-manager user's deliberate consent). Runtime pick = Docker-if-present-else-container. |
| 2026-08-19 | **0.6.7** — root-caused "web search does nothing on first use": a modal `NSAlert` (web-search consent / destructive confirm) steals key focus, so `windowDidResignKey` queued a 0.08s `hide()` that drained inside the modal loop and ordered the panel out — the result then rendered into a hidden panel. Fix: `withResignHideSuppressed` wraps both modals (`LauncherPanelController+Focus.swift`); regression `LauncherModalResignHideTests`. Search *engine* was never at fault (live probe renders both local + web). Shipped, tap mirrored. |
| 2026-08-19 | **0.6.8** — implemented #2 **local-first, web-augmented answers**: a question answers on-device immediately, then — **only once sticky "Always Allow" web consent exists** — a parallel web search replaces the card with a current, web-grounded answer + sources (`augmentAnswerWithWeb`, `answerGeneration` guards staleness, `webConsentIsSticky` gate). Preserves "no egress before opt-in / no ambient AI calls". Verified: live probe `testLocalAnswerRefinesAgainstWebWhenConsentSticky`, `make verify` green. Shipped, tap mirrored, installed + running on this host. |
| 2026-08-06 | Brand = sigil (cyan "S" + gem); supersedes v1 portal concept; app icon wired; menu-bar template produced, not wired |
| 2026-08-06 | W1 → native creation (launcher-inline snippet/quicklink); CLI retained as fallback |
| 2026-08-06 | Web search stays **opt-in** (default OFF, W1 upheld); default-ON rejected — breaks no-ambient-egress |
| 2026-08-06 | Search = RAG grounding for on-device synthesis (FM Tool protocol, query-only egress); provider ladder BYO-key API / user SearXNG; no native scraper reimplementation |
| 2026-08-06 | Two-app north star: launcher (no chat) + companion app via agent socket; L1 Apple FM verified live on the M4 gate host |
| 2026-08-06 | External purge resolved = phantom (walkthrough fixtures); 47 purged, real clips intact |
| 2026-08-03 | Dev ID last · cask first · ⌥Space · L1 day-1 · M4=L1 gate |
| 2026-08-04 | **D7 = MLX** · W1 OFF + localhost preset |
| 2026-08-04 | Socket default **OFF** unless `agent.socket.enabled=true` |
| 2026-08-04 | Product version **0.6.0** |
| 2026-08-05 | Empty launcher shows 5 routable starters plus recents/favorites · dismiss on focus loss · login requires an explicit first-run choice with ON recommended |
| 2026-08-04 | Superseded on 2026-08-05: empty launcher blank · login ON without a first-run choice |
| 2026-08-04 | Image clipboard history = required; bounded image/rich implementation landed; native soak remains |
| 2026-08-04 | Clipboard journal model = purge-on-delete with replay-stable dedupe identities |
| 2026-08-04 | Merge walkthrough = hermetic `scripts/verify-walkthrough.sh`; no consent mutation |
| 2026-08-05 | Agent CLI and socket use user enablement plus same-UID trust; no readable bearer token |
| 2026-08-05 | Production AI advertises L1/L0 only; L2/L3 and hash-based semantic ranking remain internal experiments |
| 2026-08-05 | The D7 process bridge is user-managed experimental L0, not the packaged brain; Summon never installs or daemonizes it |
| 2026-08-05 | Raycast-compatible extensions are deferred from R1; `SummonShim` remains a development seam and is not linked into shipping executables |
| 2026-08-05 | R1 retains active-Space focused-window snapping and a 13-action shortcut map; cross-Space moves, App Intents, EventKit, menu AX, hyperkey, and unverifiable TCC probes remain absent until live adapters and gates exist |
| 2026-08-05 | Clipboard History uses **⌥⇧C** in source and the release package; installed-build activation and physical verification remain open |

## Residual

- [~] Image/rich paths — residual verifier: screenshots, rapid copy, target-app paste, broad RTF, rendered errors, and VoiceOver.
- [~] Native daily-driver controls — build installed and running. Residual verifier: real-Mac ⌥⇧C, Clear History, ignore list, focus, IME, screenshot, hotkey conflict, destructive alert, the new inline Create form, and VoiceOver walkthrough.
- [x] Brand assets — sigil mark shipped; SVG masters + iconset/`.icns` + menu-bar template + size set in `assets/brand/sigil`; app icon wired into packaging and the installed build (SHA-verified). Residual [~]: native Finder/Spotlight/menu-bar visual review; wire the menu-bar template only if a decision reopens the SF-Symbols-only rule.
- [x] Hard latency and network-sovereignty checks are merge-gate targets in `make verify`.
- [x] Model supply chain — immutable revisions and full artifact digests use official HF values; valid/tampered/unmanifested-weight fixtures cover verification and quarantine.
- [~] Experimental MLX process bridge — residual verifier: live L0 on the M4 host plus an embedded authenticated runtime before the packaged-brain claim.
- [~] App Intents, menu AX, EventKit, hyperkey, browser, and unavailable TCC probes are gated off — residual verifier before reopening: live enumerator, invoker, binding, and permission-denied walkthroughs.
- [~] Extension registry and synthetic harness are development-only — residual verifier before reopening: 3 unmodified store packages through a production entry point plus denial, escape, and resource-limit suites.
- [ ] Notarized cask and Developer ID — verifier: approval-gated signing, notarization, install, upgrade, rollback, and uninstall walkthrough.
- [~] Window layout adapter — focused-display selection, primary-origin conversion, active-Space policy, AX errors, and the full shortcut map have automated coverage; residual verifier: stacked-display and permission-denied real-Mac walkthrough.
- [~] Localization key seam — residual verifier: consume keys in AppKit and run the declared locale completeness gate.

## Ladder

Apple Foundation Models is available on the M4 gate host. A running Ollama or LM Studio server is the current local-server path. The embedded llama.cpp path remains unbuilt. Cloud model providers remain outside the product. Public rung names and Apple-first versus detected-server-first priority remain open.
