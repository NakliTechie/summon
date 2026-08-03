# NAKLITECHIE-PROJECT-STATE — Summon

*The resumability spine. Every run and every checkpoint/park-wall event writes here. This is the committed state of record; local `plan/` is gitignored scratch.*

---

## Status

**specced (bundle rev 006) · scaffolded** — repo created, spec bundle in `/docs`, no code yet.

## Adopted (from the bundle)

- **D1 — Name:** Summon (closed).
- **D5 — macOS floor:** 14.0 (L1 AI rung capability-gated at runtime).
- **D3 — Apple Foundation Models:** adopted as L1; ladder degrades to L2/L3 below floor by detection, not a setting.
- **D6 — Packaged model (L0):** Gemma 4 E2B default, E4B auto-offered ≥16GB. Apache 2.0, multimodal.
- **Search:** full ladder S1 (Spotlight) → S2 (own FTS5, consented) → S3 (semantic embeddings) in v1.
- **App Intents surface:** M2.
- **License:** AGPL-3.0. **Distribution:** Homebrew cask (`naklitechie/homebrew-tap`), signed + notarized, Sparkle appcast → GitHub Releases.

## Open (resolve with evidence, journal the decision here)

- **D2 — JS runtime for shim:** JSC-first vs embedded Node → decided at **C0** with evidence.
- **D4 — Sparkle vs custom updater:** Sparkle (probe before commit) → **C0**.
- **D7 — Embedded AI runtime:** llama.cpp+Metal vs MLX-Swift → probe at **chunk-5 open**, latency+memory evidence.
- **D8 — S3 embedding model:** EmbeddingGemma 308M vs Apache-licensed alt → probe at **chunk-5 open**, license cleanliness wins ties.

## Chunk plan (continuous run — checkpoint green = proceed immediately)

| Chunk | Contents | Checkpoint | State |
|---|---|---|---|
| 1 | Spine: action bus, SchemaGate, stores, journal, `summon-cli` skeleton | C-spine | **next** |
| 2 | Shim spike (JSC + reconciler, 3 extensions) | C0 | not started |
| 3 | Launcher core (M1), search S1 + object→action grammar | C1 | not started |
| 4 | Power modules (M2), App Intents, search S2 | C2 | not started |
| 5 | D7/D8 probe · AI ladder L0–L3 + sidecars (M3), search S3 | C3 | not started |
| 6 | Shim productionized, Raycast import, sync, i18n (M4) | C4 | not started |
| 7 | `/walkthrough` all roles, `/guide`, release dry-run | C5 | not started |

## Park walls (build against a stand-in; swap real on arrival; re-verify)

- **Signing credentials** (Developer ID + notary keys) → build ad-hoc-signed; release chunk parks at `READY-signing.md`.
- **Apple Foundation Models on CI** → L1 tests against `FakeModelRung`; real-rung re-verified on capable hardware (`READY-l1-hardware.md`).
- **Homebrew tap cask** → templated + tested against a local tap until the first notarized release exists (`READY-cask.md`).

## Log

- **2026-08-03** — Scaffolded from bundle rev 006 (`docs/summon-{vision-roadmap,agent-handoff,ux-reference}-006`). Repo `NakliTechie/summon` (public, AGPL-3.0). Root: `README.md`, `CLAUDE.md`, `AGENTS.md`, this file, `LICENSE`. No code yet. Next: Chunk 1 (spine) → C-spine.

## Dead ends

*(none yet)*
