# Summon

A sovereign, native macOS launcher. Local-first, free and open source (AGPL-3.0). No account, no server of ours, no telemetry. On-device AI as a removable sidecar.

**[📖 Visual guide](https://naklitechie.github.io/summon/guide/)** — every screen, captioned and searchable.

## Install

```bash
brew install --cask naklitechie/tap/summon
```

Requires macOS Sonoma (14)+; on-device AI needs Apple Intelligence hardware (macOS 26+). The 0.6.x build isn't notarized yet, so if macOS blocks it, open it once with right-click → Open. First launch offers a **Keep Ready at Login** choice — on by default, because clipboard history needs the app running in the background.

## Highlights

- **Launcher** — ⌥Space opens a compact bar; fuzzy-match apps, files, calculator, unit conversion, snippets, quicklinks, emoji, system commands, and window layouts. Select a result, Tab / ⌘K, act on it.
- **Clipboard history** — ⌥⇧C; local text, image, HTML, and RTF capture, with an ignore list for sensitive apps.
- **On-device AI** — ask a question and get an answer from Apple Foundation Models, on your Mac. AI *actions* ("make a snippet", "set the volume to 30") stage in amber for one-click Accept — they never auto-run.
- **Web search, your way** — a keyless Wikipedia floor by default; point it at a bundled, opt-in SearXNG for full web search. Only your query leaves, and the first search always asks permission.
- **Agent face** — a local CLI and a default-off UNIX socket; every call journaled with `actor=`.

## Shortcuts

| Action | Keys |
|---|---|
| Launcher | ⌥Space |
| Clipboard history | ⌥⇧C |
| Result actions | Tab or ⌘K |
| Arrange focused window | ⌃⌥ + arrows / U I J K / Return C / D F G |

## Sovereignty

No account. No server of ours. No telemetry, analytics, or crash reporting — not even opt-in. Data leaves the machine only on explicit user action, to the user's chosen provider. Sovereignty and AI removability are enforced as first-class test gates.

## Develop

```bash
make build     # SPM debug build
make test
make verify    # full merge gate: tests, lint, CLI, sovereignty, removability, latency
make app       # ad-hoc Summon.app under dist/
```

SPM targets: `SummonCore` · `SummonUI` · `SummonShim` (dev-only) · `SummonAI` (optional, `SUMMON_AI_ENABLED`) · `summon-cli` · `summon-app`. Design and spec docs live in [`docs/`](docs/).

## License

[AGPL-3.0](LICENSE).
