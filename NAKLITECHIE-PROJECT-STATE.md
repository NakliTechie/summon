# NAKLITECHIE-PROJECT-STATE — Summon

*The resumability spine. Every run and every checkpoint/park-wall event writes here. This is the committed state of record; local `plan/` is gitignored scratch.*

---

## Status

**C0 green (synthetic harness) · C-spine green** — JSC shim spike + fixture harness (List, Form, fetch+storage, sandbox-escape) pass under `make verify`. Real unmodified Raycast *store* extensions not yet loaded (synthetic fixtures exercise the Raycast API surface; store-extension polyfill depth is the residual risk).

## Adopted (from the bundle)

- **D1 — Name:** Summon (closed).
- **D5 — macOS floor:** 14.0 (L1 AI rung capability-gated at runtime).
- **D3 — Apple Foundation Models:** adopted as L1; ladder degrades to L2/L3 below floor by detection, not a setting.
- **D6 — Packaged model (L0):** Gemma 4 E2B default, E4B auto-offered ≥16GB. Apache 2.0, multimodal.
- **Search:** full ladder S1 (Spotlight) → S2 (own FTS5, consented) → S3 (semantic embeddings) in v1.
- **App Intents surface:** M2.
- **License:** AGPL-3.0. **Distribution:** Homebrew cask (`naklitechie/homebrew-tap`), signed + notarized, Sparkle appcast → GitHub Releases.

## Decisions journaled

- **Actor case name:** `ActorTag.ext(id:)` (keyword `extension` reserved); journal label `ext:<id>`.
- **Spine store surface:** settings only for C-spine.
- **CLI actor:** `summon-cli` → `actor=agent`; stub UI → `actor=user`.
- **GRDB:** 7.x (resolved 7.11.1).
- **Removability seam:** `SUMMON_AI_ENABLED=0` omits SummonAI product/target.
- **D2 — JS runtime (provisional at C0):** **JavaScriptCore first.** Evidence: per-extension `JSContext`, CommonJS `require` allow-list (`react`, `@raycast/api` only), filesystem/`fs` denied, fetch entitlement-gated, 3 synthetic fixtures + sandbox escape green. Revisit only if a real store extension needs Node APIs JSC cannot polyfill — evidence then.
- **C0 scope honesty:** fixtures are synthetic Raycast-API-shaped commands, not yet unmodified store packages. Productionized 10-extension bar is C4.

## Open

- **D4 — Sparkle vs custom updater:** probe before commit; with C0/C1.
- **D7 — Embedded AI runtime:** llama.cpp+Metal vs MLX-Swift → chunk-5 open.
- **D8 — S3 embedding model:** EmbeddingGemma 308M vs alt → chunk-5 open.
- **Real Raycast store extensions:** load 3 unmodified store packages against the harness; expand polyfills as needed.

## Chunk plan

| Chunk | Contents | Checkpoint | State |
|---|---|---|---|
| 1 | Spine | C-spine | **green** |
| 2 | Shim spike | C0 | **green (synthetic harness)**; real store exts residual |
| 3 | Launcher core (M1), search S1 | C1 | **next** |
| 4 | Power modules (M2), App Intents, S2 | C2 | not started |
| 5 | D7/D8 · AI ladder · S3 | C3 | not started |
| 6 | Shim productionized, Raycast import, sync, i18n | C4 | not started |
| 7 | walkthrough, guide, release dry-run | C5 | not started |

## Park walls

- Signing credentials → ad-hoc-signed; `READY-signing.md`.
- Apple Foundation Models on CI → `FakeModelRung`; `READY-l1-hardware.md`.
- Homebrew tap cask → `READY-cask.md`.

## Log

- **2026-08-03** — Scaffolded from bundle rev 006.
- **2026-08-03** — C-spine. SummonCore + CLI + stub UI. `make verify` exit 0.
- **2026-08-03** — Autopilot: C0 JSC shim (`ShimRuntime`, bootstrap `@raycast/api` surface, `FixtureHarness`), SwiftLint + removability in gate. `make verify` exit 0 (30 tests + cli-e2e + lint + removability). D2 provisional JSC. Next: Chunk 3 (M1 launcher core) or real store-extension pass.

## Dead ends

*(none yet)*
