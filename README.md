# Summon

A sovereign, native macOS launcher. Local-first, free, open source (AGPL-3.0). No account, no server, no telemetry. On-device AI as a removable sidecar.

**[📖 Visual guide](https://naklitechie.github.io/summon/guide/)** — every screen, captioned and searchable.

## Install

```bash
brew install --cask naklitechie/tap/summon
```

macOS Sonoma 14+ (on-device AI needs Apple Intelligence / macOS 26+). The 0.6.x build is ad-hoc signed, not notarized — if macOS blocks it, right-click → Open once. First launch offers **Keep Ready at Login** (on by default; clipboard history needs the background app).

## Highlights

- **Launcher** — ⌥Space: fuzzy-match apps, files, calculator, unit conversion, snippets, quicklinks, emoji, system commands, window layouts. Select → Tab / ⌘K → act.
- **Clipboard history** — ⌥⇧C: local text, image, HTML, RTF, with an ignore list for sensitive apps.
- **On-device AI** — answers from Apple Foundation Models, on your Mac. Safe actions run instantly ("set the volume to 30"); destructive ones ("empty the trash") stage in amber for one-click Accept. The model never claims an action it didn't run.
- **Web search** — keyless Wikipedia floor by default; opt-in SearXNG for full search. Only your query leaves; the first search asks permission.
- **Agent face** — local CLI + default-off UNIX socket; every call journaled with `actor=`.

## Built on Apple frameworks

Apple-native throughout — no Electron, no web view: **AppKit/SwiftUI** for the UI, **Apple Foundation Models** for on-device AI, and **Apple's `container`** runtime for the opt-in web-search backend (no Docker Desktop, no license; Docker is a fallback).

## Shortcuts

| Action | Keys |
|---|---|
| Launcher | ⌥Space |
| Clipboard history | ⌥⇧C |
| Result actions | Tab or ⌘K |
| Arrange focused window | ⌃⌥ + arrows / U I J K / Return C / D F G |

## Sovereignty

No account, no server, no telemetry — not even opt-in. Data leaves only on explicit action, to your chosen provider. Sovereignty and AI removability are enforced as first-class test gates.

## Develop

```bash
make build     # SPM debug build
make test
make verify    # merge gate: tests, lint, CLI, sovereignty, removability, latency
make battery   # gated batteries: 1000-probe routing + deterministic-surface + Macaw-parity
make app       # ad-hoc Summon.app under dist/
```

SPM targets: `SummonCore` · `SummonUI` · `SummonShim` (dev-only) · `SummonAI` (optional, `SUMMON_AI_ENABLED`) · `summon-cli` · `summon-app`. Specs in [`docs/`](docs/).

## License

[AGPL-3.0](LICENSE).
