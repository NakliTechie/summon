<h1 align="center">Summon</h1>

<p align="center"><b>A sovereign, native macOS launcher with on-device AI.<br>
Summon apps, files, your clipboard, and answers — from one keystroke, on your Mac.</b></p>

<p align="center"><i>One app. macOS Sonoma 14+. No account, no server, no telemetry.</i></p>

<p align="center">
<img alt="Latest release" src="https://img.shields.io/github/v/release/NakliTechie/summon?style=flat-square&color=0F1A1F">
<img alt="License AGPL-3.0" src="https://img.shields.io/badge/license-AGPL--3.0-0F1A1F?style=flat-square">
<img alt="Telemetry: none" src="https://img.shields.io/badge/telemetry-none-0F1A1F?style=flat-square">
<img alt="AI: on-device" src="https://img.shields.io/badge/AI-on--device-0F1A1F?style=flat-square">
</p>

**[📖 Visual guide](https://naklitechie.github.io/summon/guide/)** — every screen, captioned and searchable.

## Install

| Platform | Command |
|---|---|
| macOS (Homebrew) | `brew install --cask naklitechie/tap/summon` |

Press **⌥Space** to open the launcher; it lives in the menu bar and captures your clipboard in the background. The first launch offers **Keep Ready at Login** (on by default). Point another tool at it over the local agent socket:

```bash
summon agent version          # the CLI face; the UNIX socket is default-off
```

No config file, no account, no restart. The build is ad-hoc signed, not notarized — if macOS blocks it, right-click → Open once (or `xattr -dr com.apple.quarantine "/Applications/Summon.app"`).

## Why

You reach for a launcher a hundred times a day, and it either respects that your Mac is yours or it doesn't. Summon keeps everything local: the index, the clipboard, the AI. No account to make, no server of ours to trust, nothing phoning home — not even opt-in telemetry.

**Use something else if:** you want the deepest third-party extension ecosystem — [Raycast](https://raycast.com) (proprietary, cloud AI, account) is far richer. You want a mature, scriptable workflow engine — [Alfred](https://www.alfredapp.com) (proprietary, paid Powerpack) is the standard. You just want app search and nothing more — Spotlight ships with macOS. Summon is for wanting a launcher *and* on-device AI *and* sovereignty in one tool.

## On-device AI, and Smart Paste

Answers come from **Apple Foundation Models**, on your Mac. Ask a question and it answers inline; ask for a safe action ("set the volume to 30") and it runs; ask for a destructive one ("empty the trash") and it stages in amber for one-click Accept. The model never claims an action it didn't run — [how the harness guarantees that](docs/harness.md).

**Smart Paste (⌥⌘V)** reads what you copied — a contact block, a signature — and fills a form's fields by meaning: email into Email, phone into Phone, name into the name field. Clean fields route instantly on-device; anything unclear is decided by a small local model. Every fill is reversible from the toast, and secure fields are never touched.

## Web search and the agent face

Web search is off until you ask for it: a keyless Wikipedia floor by default, opt-in **SearXNG** for full search on Apple's `container` runtime (no Docker Desktop; Docker is a fallback). The first search asks permission; SearXNG may forward the query to its configured upstream engines.

Every capability is reachable by machine: a local CLI and a default-off UNIX socket, each call journaled with `actor=`. Two doors, one core.

## Keys and commands

```
⌥Space                          open the launcher
⌥⇧C                             clipboard history (text · image · HTML · RTF)
⌥⌘V                             Smart Paste into the frontmost form
Tab  or  ⌘K                     act on the selected result
⌃⌥ + arrows / U I J K / ⏎ C     arrange the focused window
```

## Verify it yourself

```bash
make verify    # merge gate: tests, lint, CLI e2e, sovereignty, no-model launcher, latency
```

The gate refuses a network primitive outside the two declared egress files, refuses an AI action that reports success without running, and refuses a launcher that dead-ends when no model is present. Sovereignty and no-model degradation are first-class test gates, run on every merge.

## License

[AGPL-3.0](LICENSE). Founding docs and specs in [`docs/`](docs/) · what shipped in the [CHANGELOG](CHANGELOG.md).
