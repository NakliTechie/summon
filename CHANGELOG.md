# Changelog

Notable changes to Summon. Versions follow semver; the 0.6.x line ships
ad-hoc-signed (not yet Apple-notarized).

## 0.6.7 — 2026-08-19

### Fixed
- Web search no longer "does nothing" on first use: the consent dialog took key
  focus, which tripped the launcher's dismiss-on-blur and ordered the panel out
  mid-dialog — so the spinner and answer rendered into an already-hidden window.
  The launcher now stays put across the consent and destructive-confirm dialogs.

## 0.6.6 — 2026-08-09

### Fixed
- Focus returns to the app you were using when the launcher or clipboard-history
  window dismisses — so a copied emoji or clipboard item is ready to paste without
  clicking back into your app.

## 0.6.5 — 2026-08-09

### Added
- Tier-1 local model: Summon silently detects and uses a running **Ollama / LM
  Studio** server (loopback, OpenAI-compatible), preferred over Apple Foundation
  Models — so "Ask local AI" and web-search answers work **without Apple
  Intelligence**, entirely on-machine.

### Fixed
- Web search no longer dead-ends ("could not connect") when a configured SearXNG
  is unreachable — it falls back to the keyless **Wikipedia floor**. Fresh
  installs no longer preset a phantom SearXNG endpoint.

### Changed
- AI is core, not a removable sidecar; Apple Silicon only.

## 0.6.4 — 2026-08-09

### Fixed
- Web search no longer dead-ends on Macs without Apple Intelligence: when no
  on-device model is available to synthesize an answer, it returns the fetched
  web results (links) instead of failing silently. With Apple Intelligence on,
  answers are still synthesized on-device.

## 0.6.3 — 2026-08-09

### Added
- First-run onboarding: four skippable native intro screens (⌥Space · ask
  anything · do things safely · get set up), with the "keep ready at login"
  choice folded into the last screen.
- One-consent full web search: a single opt-in — the onboarding checkbox or a
  Preferences "Set up full web search" button — sets up SearXNG in the background
  (reusing Docker if present, else installing Apple's `container` runtime) and
  turns it on. Non-blocking progress shows in the launcher footer.

## 0.6.2 — 2026-08-09

### Changed
- Action classifier is more robust: strips polite lead-ins ("please", "can you",
  "hey summon", …), recognizes keyword volume levels (mute/silence/max/full) and
  the two-word "screen shot", and honestly declines messaging beyond Mail/Messages
  (WhatsApp/iMessage, dm/reply) instead of guessing.

### Added
- `RoutingBattery1000Tests` — a 1000+-probe routing battery (search vs safe-run vs
  destructive-stage vs honest-decline). Run all batteries with `make battery`.
- Product page: brand sigil and a one-click copy button on the install command.

## 0.6.1 — 2026-08-09

### Changed
- Opt-in SearXNG web search now runs on **Apple's `container` runtime** by
  default (Apple silicon + macOS 26) — Apple-native, no Docker Desktop, no
  license. Docker/colima remains a fallback for Intel or older macOS; force
  either with `SUMMON_SEARXNG_RUNTIME=container|docker`. The loopback-only bind
  (and the sovereignty guard that enforces it) is preserved on both runtimes.
- `searxng-down.sh` on the `container` path removes the instance and reclaims
  its VM disk immediately.
- Docs and product copy updated to reflect the "do the safe thing, confirm the
  destructive thing" action model.

## 0.6.0 — 2026-08-07

- First public cask release: compact ⌥Space launcher, ⌥⇧C clipboard history,
  on-device AI (answers + staged actions), opt-in web search, and a default-off
  agent socket. Fully local — no account, no server, no telemetry.
