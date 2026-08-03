# Summon

> A sovereign, native macOS launcher. Every SuperCmd-class module — no account, no server, no telemetry. AI as a removable sidecar riding the on-device ladder.

**Status:** pre-release, in active development. Nothing here ships until `make verify` is green in a fresh checker context.

Summon is a native macOS launcher (Swift, AppKit + SwiftUI) built around one idea: the single most intimate tool on your machine should keep that intimacy on your disk. Free, open source, AGPL-3.0. No account anywhere. No server of ours in the loop. No telemetry at all.

## What it does

- **Launch** apps and files, with a search *ladder*: Spotlight index (zero cost) → your own opt-in full-text index → semantic recall on top.
- **Act** on any result — LaunchBar's object→action grammar revived (select a thing, Tab, act on it).
- **Remember** — unlimited clipboard history and snippets, stored locally in SQLite, exportable to JSON.
- **Manage** windows, spaces, screenshots, and system commands from the bar.
- **Extend** — run unmodified Raycast extensions via a sandboxed shim, and consume every installed app's App Intents actions natively.
- **Ask** — AI as a removable sidecar. Zero-key on-device model as the ground floor; Apple Foundation Models, a detected local runtime, or your own key above it. Every AI output is *staged* for your review before anything runs.

## Sovereignty

No account. No server of ours. No telemetry, analytics, or crash reporting — not even opt-in. This is auditable fact, not a privacy-page claim: the network gate in the test suite asserts the only egress is the update check (and any AI call *you* invoke, to *your* own provider).

"Local" means different things per AI rung, and Summon states which honestly per invocation — the Sidecar honesty rule.

## Install

```bash
brew install --cask naklitechie/tap/summon
```

*(Available once the first notarized release ships.)*

## Agent face

Every module is callable by a machine over the same core the hotkey drives — a CLI and a local UNIX socket, off by default, enabled in developer settings, every call journaled. This makes Summon a tool surface for coding agents, not a launcher with a captive agent.

```bash
summon run window.arrange --layout=left-right
summon clipboard search "invoice"
echo "..." | summon quickfix --tone=formal
```

## License

[AGPL-3.0](LICENSE).

---

*Project docs (vision, roadmap, agent handoff, UX reference) live in [`/docs`](docs/). Operational state lives in [`NAKLITECHIE-PROJECT-STATE.md`](NAKLITECHIE-PROJECT-STATE.md).*
