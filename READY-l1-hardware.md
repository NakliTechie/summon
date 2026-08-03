# READY-l1-hardware — Apple Foundation Models (L1) gate

**Status:** primary gate host designated.

## Gate host

| Field | Value |
|---|---|
| Machine | Chirag’s **M4 Pro** Mac (this development machine) |
| OS | macOS 26.x (Apple Intelligence capable) |
| Role | Real-rung L1 verification |
| Designated | 2026-08-03 |

## Policy

- **CI / default suite:** `FakeModelRung` only.
- **This machine:** `make l1-probe` exercises real `SystemLanguageModel`.
- App floor remains **macOS 14**; L1 is **runtime capability-gated** (D3/D5).
- **Day-1 product rule:** Apple native AI is first-class L1 on capable hardware.

## Commands

```bash
make l1-probe
swift run summon-cli ai status
swift run summon-cli ai complete "Reply with: pong"
```
