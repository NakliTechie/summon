# Summon-managed SearXNG (opt-in current-web search)

The privacy-maximalist rung of Summon's search ladder. Ships **ready to go** so
that if you opt in later, it's one command — no hunting through SearXNG docs.

Summon **never** installs a container runtime, never auto-starts this, and
nothing runs until you opt in. SearXNG binds to `127.0.0.1` only, with the JSON
API enabled (Summon's `SearXNGClient` queries `?format=json`), so the app's
loopback-only sovereignty guard holds whichever runtime starts it.

## Runtime

`searxng-up.sh` prefers Apple's **`container`** — Apache-2.0, Apple-native, no
Docker Desktop and no license — and falls back to **Docker/colima** on Intel
Macs or macOS < 26. Each `container` instance is its own lightweight VM, so the
Docker cap-drop hardening isn't needed on that path.

## Opt in

```bash
./searxng-up.sh     # picks a runtime, pulls the image, generates a secret, starts on 127.0.0.1
```

Then in Summon, pick the **SearXNG** search provider (the recorded loopback URL
is auto-discovered — no port to configure).

## Opt out

```bash
./searxng-down.sh
```

On the `container` runtime this removes the instance and **reclaims its VM disk
(~1.5 GB) immediately**; the cached image stays for a fast restart. To reclaim
that too, `container image rm docker.io/searxng/searxng:latest`.

## Requirements

- **Recommended:** Apple silicon + macOS 26+, then `brew install container`.
- **Fallback:** Docker Desktop or colima.
- `searxng-up.sh` checks for a runtime and tells you if none is present.

## Footprint (opt-in only)

The SearXNG image is the heavy part on either runtime — ~1.5 GB materialized
under `container`'s per-VM filesystem, ~0.6–1 GB under Docker's overlay. The
default keyless Wikipedia floor needs **no runtime and no image**; this cost
lands only if you enable full web search.

## Files

- `docker-compose.yml` — loopback-only SearXNG service (Docker fallback path).
- `settings.yml` — minimal override (JSON on, `use_default_settings: true`); a
  template — the real secret is generated into `runtime/settings.yml` (gitignored).
- `searxng-up.sh` / `searxng-down.sh` — bring up / tear down (runtime-agnostic).
