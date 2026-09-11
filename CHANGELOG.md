# Changelog

Notable changes to Summon. Versions follow semver; the 0.6.x line ships
ad-hoc-signed (not yet Apple-notarized).

## 0.7.0 — 2026-09-12

The web-search backend lifecycle, hardened against a two-day adversarial run
(`plan/harden-2026-09-10.md`): every claim the surface makes about the
app-owned SearXNG container is now verified before it is said.

### Added
- `summon web remove [--purge-image]` and `summon web status`. Disable now stops
  the app-owned container and keeps its data; Remove deletes the container (and
  its volumes on Docker) and the recorded URL; the image is purged only on request.
- Launch-time reconcile: a backend the user left enabled is restored after a
  crash, reboot, or runtime restart — bounded (3 attempts, 2 s / 5 s backoff),
  cancellable, and only for a container this profile set up.
- Preferences → Search shows the backend state and offers "Remove local backend…"
  with an explicit confirmation and an opt-in image purge.
- Ownership evidence: the container name is global to the runtime, so the
  recorded URL written by Summon's own setup is what lets enable / disable /
  remove act. Another profile sees `owned=no` and is refused.

### Changed
- "Restored at <url>" is said only after the container publishes a live port and
  answers a journaled loopback probe; a port taken by another process is reported
  as unpublished and never recorded.
- A search uses the recorded backend only while it is verifiably running on that
  port right now; otherwise the keyless floor answers with a note. A fallback
  answer from `web answer` names the provider that failed.
- `searxng-up.sh`: inspect → reuse → unpause / start → recreate only after a
  failed start or `SUMMON_SEARXNG_RECREATE=1`; plain `docker run` (no compose
  plugin needed); two racing bring-ups resolve to one container; log tail on failure.
- Paused and crash-looping containers are named as such instead of "stopped".
- The recorded URL and the default store both follow `$HOME`, so an isolated HOME
  can no longer read or delete the real user's state.
- Web verbs reject unknown flags and extra tokens instead of ignoring them.

### Fixed
- `web enable` exits 1 when the backend could not be restored; `web search` no
  longer demands `web.search.baseURL` when a recorded backend exists.
- A subprocess whose helper kept the output pipe open, or whose exit Foundation
  never observed, could park the lifecycle indefinitely; completion now rides on
  the termination handler with a bounded drain and a kill escalation.
- `searxng-down.sh --help` no longer prints a shell directive, and works from any
  directory.

### Removed
- `packaging/searxng/docker-compose.yml` — the Docker path no longer depends on
  the compose CLI plugin.

## 0.6.8 — 2026-08-19

### Added
- Local-first answers that refine against the web. A question is answered
  on-device instantly; once you've granted "Always Allow" web consent, Summon
  then quietly runs a web search in parallel and upgrades the card to a current,
  web-grounded answer with sources — no waiting on the network to see something,
  and no egress before that one-time opt-in.

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
