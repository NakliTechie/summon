# Changelog

Notable changes to Summon. Versions follow semver; the 0.6.x line ships
ad-hoc-signed (not yet Apple-notarized).

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
