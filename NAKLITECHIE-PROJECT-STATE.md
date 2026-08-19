# NAKLITECHIE-PROJECT-STATE — Summon

## Status

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
- Experimental local L0 uses immutable official revisions, full artifact digests, exact-model consent, quarantine, and bounded user-managed MLX/Hugging Face processes
- The native launcher offers explicit AI staging on missed natural-language queries, retains edit/accept/reject review, and exposes ladder availability through AI Status
- `make verify` requires full and AI-off suites, CLI e2e, lint, extension omission, walkthrough, network sovereignty, version consistency, and hard latency
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

L1 Apple FM — **verified available now** on the M4 gate host (macOS 26.5.2, 3B/2-bit, framework GA); wiring is Chunk C. → experimental user-managed L0 MLX (unavailable if binary, consent, authenticated weights, or storage is missing). Packaged L0 (llama.cpp+Metal, D7), L2, and L3 remain roadmap-only.
