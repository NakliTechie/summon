# NAKLITECHIE-PROJECT-STATE — Summon

## Status

**M1 advanced + cask-local path + agent socket default ON.**  
Gate: `make verify`. Distribution: **cask first**, Developer ID **last** in queue.

## Decisions (2026-08-03 Chirag)

| Decision | Choice |
|---|---|
| Developer ID / notary | **Later — last in queue** |
| Homebrew cask | **First** among distribution tracks — template + local dry-run now; public PR after notarized zip |
| Global hotkey | **⌥Space OK** (locked) |
| Agent socket | **Default ON** — disable via `agent.socket.enabled=false` |
| L1 AI on CI | Not a product question — see below |

### What was the “AI question”?

Not “should Summon have AI?” (ladder is already adopted). It was a **CI park wall**:

- Apple Foundation Models (L1) only run on Apple Intelligence–capable Macs + recent OS.
- GitHub Actions macOS runners often **cannot** exercise the real L1 rung.
- Plan: unit tests use `FakeModelRung`; real L1 re-verified on capable hardware → `READY-l1-hardware.md` when AI chunk lands.
- **No decision needed from you** until chunk 5 unless you want a specific machine listed as the L1 gate host.

## Cask path

- Template: `packaging/homebrew/Casks/summon.rb`
- Local dry-run: `make cask-local` (ad-hoc `Summon.app` zip + file:// cask)
- Park wall notes: `READY-cask.md`
- Unblocked for **public** brew install by: notarized GitHub Release zip (after Dev ID)

## Residual eng (no human)

Menu-item search, hyperkey, more Maccy parity, latency/network gates, real Raycast store exts.

## Chunk plan

| 1–2 | C-spine, C0 | green |
| 3 M1 | advanced | residual above |
| Dist | cask-local ready | public cask waits notarization |
| 4–7 | not started | |

## Log

- 2026-08-03 — Continuous M1. Decisions: cask-first, socket ON, ⌥Space OK, Dev ID last. Cask packaging + READY-cask.md.

## Dead ends
*(none)*
