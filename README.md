# Summon

A sovereign, native macOS launcher. Local-first. Free and open source (AGPL-3.0). No account, no server of ours, no telemetry. AI is a removable sidecar on an on-device ladder.

**Status:** pre-release daily-driver builds (v0.6.x). Signed/notarized Homebrew cask is not shipped yet.

## Highlights

- **Launcher** — ⌥Space opens a compact search bar (Spotlight-style: thin until you type, then results expand).
- **Search ladder** — apps and files via the system metadata index, optional full-text (FTS, consent-gated), room for semantic recall later.
- **Object → action** — select a result, Tab / ⌘K, choose an action.
- **Clipboard history** — resident capture while Summon runs; dedicated browser on **⌥⇧V** (text today; image history planned).
- **Snippets, quicklinks, calc, emoji**, window layouts, and more modules on the same core.
- **Extensions** — sandboxed JS shim for third-party packages; App Intents surface evolving.
- **AI** — staged only (never auto-executes); L1 Apple Foundation Models / L0 packaged model when configured; compile-out removability gate.
- **Agent face** — CLI + optional UNIX socket (default **off**), every call journaled with `actor=`.

## Use (local build)

```bash
cd /path/to/summon
make app
pkill -x summon-app 2>/dev/null
rm -rf /Applications/Summon.app
cp -R dist/Summon.app /Applications/
open /Applications/Summon.app
```

| Action | How |
|---|---|
| Open launcher | **⌥Space** (or menu bar 🔍 → Show Launcher) |
| Clipboard history | **⌥⇧V** (or menu → Clipboard History) |
| Quit | Menu bar → Quit |

Launch at login defaults **on** (menu bar can toggle). Clipboard history needs the app process running in the background.

**Install via Homebrew** (when the first notarized release exists):

```bash
brew install --cask naklitechie/tap/summon
```

## Develop

```bash
make build          # SPM debug
make test
make verify         # merge gate (tests, cli-e2e, lint, removability, walkthrough, latency-soft)
make app            # ad-hoc Summon.app under dist/
```

SPM targets: `SummonCore` · `SummonUI` · `SummonShim` · `SummonAI` (optional via `SUMMON_AI_ENABLED`) · `summon-cli` · `summon-app`.

CLI (from SPM build):

```bash
BIN="$(swift build --show-bin-path)/summon-cli"
"$BIN" search "2+2"
"$BIN" clipboard list
"$BIN" settings get agent.socket.enabled
```

## Spec & ops

| Doc | Role |
|---|---|
| [`docs/summon-vision-roadmap-006.md`](docs/summon-vision-roadmap-006.md) | Vision, invariants, modules, AI ladder |
| [`docs/summon-agent-handoff-006.md`](docs/summon-agent-handoff-006.md) | Build, gate, security, hard rules |
| [`docs/summon-ux-reference-006.html`](docs/summon-ux-reference-006.html) | Drawn UX reference |
| [`NAKLITECHIE-PROJECT-STATE.md`](NAKLITECHIE-PROJECT-STATE.md) | Current position / residuals |
| [`AGENTS.md`](AGENTS.md) | Notes for coding agents |

## Sovereignty

No account. No server of ours. No telemetry, analytics, or crash reporting — not even opt-in. AI data leaves the machine only on **explicit** user action, to **the user’s** provider. The test suite tracks sovereignty and AI removability as first-class gates.

## License

[AGPL-3.0](LICENSE).
