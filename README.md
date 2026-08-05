# Summon

A sovereign, native macOS launcher. Local-first. Free and open source (AGPL-3.0). No account, no server of ours, no telemetry. AI is a removable sidecar on an on-device ladder.

**Status:** pre-release daily-driver builds (v0.6.x). Signed/notarized Homebrew cask is not shipped yet.

## Highlights

- **Launcher** — ⌥Space opens a compact search bar (Spotlight-style: thin until you type, then results expand).
- **Search ladder** — apps and files via the system metadata index, optional full-text (FTS, consent-gated), room for semantic recall later.
- **Object → action** — select a result, Tab / ⌘K, choose an action.
- **Clipboard history** — resident text, image, HTML, and RTF capture while Summon runs; dedicated browser on **⌥⇧V**.
- **Snippets, quicklinks, calc, emoji**, window layouts, and more modules on the same core.
- **Extensions** — deferred from R1. The registry/JSC harness remains a development target; shipping executables expose no installer, grants, results, or runner.
- **AI** — staged only (never auto-executes); capability-gated L1 Apple Foundation Models plus an experimental, consented, user-managed L0 MLX adapter; compile-out removability gate.
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
| Arrange focused window | **⌃⌥** + arrows, U/I/J/K, Return/C, or D/F/G |
| Quit | Menu bar → Quit |

First launch offers an explicit **Keep Ready at Login** choice. The recommended choice is on because clipboard history needs the app process running in the background. Preferences and the menu bar can change it later.

## Current verification boundaries

- [~] Image and rich clipboard storage has automated coverage. Residual verifier: copy screenshots, HTML, and RTF between real Mac applications; inspect target-app paste, rapid-copy retention, rendered failures, and VoiceOver.
- [~] Window layout targets the focused window on its display, uses the primary-display AX origin, and registers a stable 13-action shortcut map. Cross-Space moves are omitted because macOS has no public API for them. Residual verifier: exercise stacked displays, active Spaces, AX failures, and every shortcut on a real Mac.
- [~] App Intents, EventKit Calendar, menu AX, hyperkey, Full Disk Access probing, and Screen Recording probing are deferred from R1. Their explicit fixture/configuration seams produce no production results or optimistic permission state. Residual verifier before reopening: live enumerators, invokers, bindings, and permission-denied walkthroughs against installed applications.
- [~] Raycast-compatible extensions are deferred from R1. `SummonShim` retains registry, grants, JSC runtime, and synthetic fixtures as development seams, while `summon-app` and `summon-cli` do not depend on or link them. Residual verifier before reopening the surface: run 3 unmodified store packages through production install, grant, render, invoke, restart, removal, denial, escape, and resource-limit journeys.
- [~] AI embeds immutable official revisions and full inference-artifact manifests; valid/tampered fixtures cover verification and quarantine. The native launcher can stage missed typed intent and shows unavailable states. L0 is an experimental user-managed process adapter, not the packaged brain; hash ranking and L2/L3 detection remain internal experiments. Residual verifier: explicitly consent to the 5.2 GB L0 download, exercise live generation on the M4 host, then replace the bridge with an embedded authenticated runtime before calling L0 packaged.

**Install via Homebrew** (when the first notarized release exists):

```bash
brew install --cask naklitechie/tap/summon
```

## Develop

```bash
make build          # SPM debug
make test
make verify         # merge gate: tests, CLI, lint, removability, extension omission, walkthrough, network, version, hard latency
make app            # ad-hoc Summon.app under dist/
```

SPM targets: `SummonCore` · `SummonUI` · `SummonShim` (development-only) · `SummonAI` (optional via `SUMMON_AI_ENABLED`) · `summon-cli` · `summon-app`.

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
