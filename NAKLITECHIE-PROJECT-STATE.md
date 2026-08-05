# NAKLITECHIE-PROJECT-STATE — Summon

## Status

**2026-08-05** — Daily-driver shell on `main` (v0.6.x):

- Compact launcher (⌥Space): collapsed until type; dismiss on resign key
- Clipboard: resident image/HTML/RTF/text capture, explicit first-run login choice, dedicated history **⌥⇧V**
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

**Not** notarized / public cask yet. **Phase H** (Dev ID) remains last.

## Roadmap honesty

- [~] Earlier security batches established seams. Residual verifier: close the AI, extension-runtime, and native chunks with their named live gates.
- [~] R0 image/rich clipboard code paths have automated coverage. Residual verifier: real-Mac screenshot, rapid-copy, target-app paste, broad RTF, rendered-error, and VoiceOver walkthrough.
- [ ] Phase H notarization, public cask, and Developer ID remain a stop-line requiring explicit approval.

Inventory: local `plan/pending.md` · `plan/workplan.md` (gitignored).

## Decisions

| When | Decision |
|---|---|
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

## Residual

- [~] Image/rich paths — residual verifier: screenshots, rapid copy, target-app paste, broad RTF, rendered errors, and VoiceOver.
- [~] Native daily-driver controls — residual verifier: real-Mac Clear History, ignore list, focus, IME, screenshot, hotkey conflict, destructive alert, and VoiceOver walkthrough.
- [x] Hard latency and network-sovereignty checks are merge-gate targets in `make verify`.
- [x] Model supply chain — immutable revisions and full artifact digests use official HF values; valid/tampered/unmanifested-weight fixtures cover verification and quarantine.
- [~] Experimental MLX process bridge — residual verifier: live L0 on the M4 host plus an embedded authenticated runtime before the packaged-brain claim.
- [~] App Intents, menu AX, EventKit, hyperkey, browser, and unavailable TCC probes are gated off — residual verifier before reopening: live enumerator, invoker, binding, and permission-denied walkthroughs.
- [~] Extension registry and synthetic harness are development-only — residual verifier before reopening: 3 unmodified store packages through a production entry point plus denial, escape, and resource-limit suites.
- [ ] Notarized cask and Developer ID — verifier: approval-gated signing, notarization, install, upgrade, rollback, and uninstall walkthrough.
- [~] Window layout adapter — focused-display selection, primary-origin conversion, active-Space policy, AX errors, and the full shortcut map have automated coverage; residual verifier: stacked-display and permission-denied real-Mac walkthrough.
- [~] Localization key seam — residual verifier: consume keys in AppKit and run the declared locale completeness gate.

## Ladder

L1 Apple → experimental user-managed L0 MLX (unavailable if binary, consent, authenticated weights, or storage is missing). Packaged L0, L2, and L3 remain roadmap-only.
