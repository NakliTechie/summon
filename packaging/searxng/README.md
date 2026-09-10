# Summon-managed SearXNG (opt-in current-web search)

The privacy-maximalist rung of Summon's search ladder. Ships **ready to go** so
that if you opt in later, it's one command — no hunting through SearXNG docs.

Summon **never** installs a container runtime and nothing runs until you opt in.
The opt-in is the explicit setup action ("Set up full web search", or running
`searxng-up.sh` yourself), which records the backend's URL; the "Search the web"
preference alone starts nothing, because there is no app-owned container until
setup has run. After setup, Summon restores a stopped instance at launch and on
re-enable while web search stays on, and stops it when you turn web search off.
SearXNG binds to `127.0.0.1` only, with the JSON API
enabled (Summon's `SearXNGClient` queries `?format=json`), so the app's
loopback-only sovereignty guard holds whichever runtime starts it.

## Runtime

`searxng-up.sh` prefers Apple's **`container`** — Apache-2.0, Apple-native, no
Docker Desktop and no license — and falls back to **Docker/colima** on Intel
Macs or macOS < 26. Each `container` instance is its own lightweight VM, so the
Docker cap-drop hardening isn't needed on that path.

## Lifecycle

Summon owns exactly one container, `summon-searxng`, and addresses it by name.
It never touches other containers and never runs `container system stop`: the
runtime is shared, and another tool may have started using it since.

| Intent | Command | Effect |
|---|---|---|
| Set up / re-enable | `./searxng-up.sh` | inspect → reuse if healthy → start if stopped → create if missing |
| Disable | `./searxng-down.sh` | stop the service; container, settings and data kept |
| Remove local backend | `./searxng-down.sh --remove` | delete the container and the recorded URL; image kept |
| Remove + image | `./searxng-down.sh --remove --purge-image` | also delete the SearXNG image |
| Explicit rebuild | `SUMMON_SEARXNG_RECREATE=1 ./searxng-up.sh` | remove and recreate the container (e.g. after an image update) |

A failed health check never deletes the container by itself: `searxng-up.sh`
recreates only when an existing instance stays unhealthy after a start attempt,
or when `SUMMON_SEARXNG_RECREATE=1` asks for it. On failure the script prints
the runtime's last 40 log lines and leaves the container in place for
`container logs summon-searxng` / `docker logs summon-searxng`. Two bring-ups
racing to create the container resolve to one instance: the loser reuses it.

The same verbs are available from the app (Preferences → Search) and the CLI:

```bash
summon web enable            # persist on; restore a stopped app-owned backend
summon web disable           # persist off; stop the backend, keep its data
summon web remove            # persist off; delete the app-owned container
summon web remove --purge-image
summon web status            # preference + observed backend state
```

Recovery is bounded: three start attempts with 2 s and 5 s backoff, cancelled
when the feature is disabled. The Apple runtime is started once if it is down,
and only when a recorded URL shows Summon's own setup ran — a runtime installed
for other reasons is never booted by the launcher. Docker Desktop is a GUI app
and is never launched from the app at startup; only an explicit `searxng-up.sh`
run (the setup button, or you at a terminal) opens Docker Desktop or starts
colima when the Docker daemon is down.

## Requirements

- **Recommended:** Apple silicon + macOS 26+, then `brew install container`.
- **Fallback:** Docker Desktop or colima.
- `searxng-up.sh` checks for a runtime and tells you if none is present.

## Footprint (opt-in only)

The SearXNG image is the heavy part on either runtime — ~1.5 GB materialized
under `container`'s per-VM filesystem, ~0.6–1 GB under Docker's overlay. The
default keyless Wikipedia floor needs **no runtime and no image**; this cost
lands only if you enable full web search. Disable keeps the footprint for a fast
restart; Remove reclaims the container's disk, and `--purge-image` the rest.

## Files

- `settings.yml` — minimal override (JSON on, `use_default_settings: true`); a
  template — the real secret is generated into `runtime/settings.yml` (gitignored).
- `searxng-up.sh` / `searxng-down.sh` — set up or restore / disable or remove.
  The Docker path uses plain `docker run` (loopback bind, read-only settings
  mount, all capabilities dropped but CHOWN/SETGID/SETUID, bounded logs,
  `--restart unless-stopped`); no compose plugin is required.
