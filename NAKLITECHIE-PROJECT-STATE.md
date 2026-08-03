# NAKLITECHIE-PROJECT-STATE — Summon

*The resumability spine. Every run and every checkpoint/park-wall event writes here.*

---

## Status

**C1-core green · C0 · C-spine** — filter grammar, S1 search seam (FakeSpotlight + mdfind adapter), object→action grammar, app catalog, calculator, snippet store on the bus. Full M1 inventory (clipboard/hotkeys/UI panel/emoji/…) still open. `make verify` green (45 tests + cli-e2e + lint + removability).

## Adopted

- D1 Summon · D5 macOS 14 · D3 L1 AFMs · D6 Gemma 4 E2B · Search ladder S1–S3 · App Intents M2 · AGPL-3.0 + Homebrew cask.

## Decisions journaled

- ActorTag.ext · GRDB 7.x · SUMMON_AI_ENABLED=0 removability.
- D2 provisional JSC (synthetic C0).
- **C1 store schema v2:** `snippets` table; snapshot includes snippets for byte-equal replay.
- **S1 seam:** `SpotlightIndexing` protocol; tests use `FakeSpotlightIndex`; production CLI calls `enableLiveSpotlight()` → `mdfind`.
- **C1-core vs full M1:** this checkpoint is the search+grammar+snippet spine, not the full SuperCmd-class module list (clipboard/hotkeys/window UI deferred to continued M1).

## Open

- D4 Sparkle · D7/D8 chunk-5 · real Raycast store extensions · remainder of M1 modules.

## Chunk plan

| Chunk | Checkpoint | State |
|---|---|---|
| 1 | C-spine | green |
| 2 | C0 | green (synthetic) |
| 3 | C1 | **C1-core green**; full M1 inventory residual |
| 4–7 | C2–C5 | not started |

## Park walls

Signing · L1 CI hardware · Homebrew cask.

## Log

- 2026-08-03 — Scaffolded; C-spine; C0 JSC shim.
- 2026-08-03 — **C1-core:** FilterGrammar, SearchService, AppCatalog, Calculator, ObjectActionGrammar, SnippetStore, CLI search/calc/snippet/actions. Verify 45 tests. Next: continue M1 modules or AppKit launcher panel against UX reference.

## Dead ends

*(none yet)*
