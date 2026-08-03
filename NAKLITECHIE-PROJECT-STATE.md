# NAKLITECHIE-PROJECT-STATE — Summon

## Status

**L1 day-1 live on M4 Pro** · M1 advanced · C0 · C-spine.  
`make verify` green. `make l1-probe` → L1 **available** on this host.

## Decisions (Chirag 2026-08-03)

| Decision | Choice |
|---|---|
| Dev ID / notary | Last in queue |
| Homebrew cask | First dist track (`make cask-local` ready) |
| ⌥Space | Locked OK |
| Agent socket | Default ON |
| Apple Foundation Models | **Day-1 L1**, capability-gated; this **M4 Pro** is the real-rung gate host |
| macOS floor | Still 14; L1 requires 26+ AI-capable hardware at runtime |

## L1 hardware gate

See `READY-l1-hardware.md`. CI uses `FakeModelRung`. This machine runs real `SystemLanguageModel`.

## AI architecture (day-1)

- `ModelRung` protocol (ours) — never Apple’s protocol as the core
- `AppleFoundationModelRung` adapter (`FoundationModels`)
- `FakeModelRung` for CI / removability
- `AILadder` detection + `SummonAIService` staged completions (never auto-exec)
- CLI: `summon ai status|complete`
- L0/L2/L3 still deferred to chunk 5 probes

## Residual

Menu-item search, hyperkey, Maccy parity depth, public cask after notarization, L0 pack, latency/network gates.

## Log

- 2026-08-03 — L1 day-1 scaffold; live probe green on M4 Pro.

## Dead ends
*(none)*
