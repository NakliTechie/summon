# Summon-managed SearXNG (opt-in current-web search)

The privacy-maximalist rung of Summon's search ladder. Ships **ready to go** so
that if you opt in later, it's one command — no hunting through SearXNG docs.

Summon **never** installs Docker, never auto-starts this, and nothing runs until
you opt in. SearXNG binds to `127.0.0.1:8080` only, with the JSON API enabled
(Summon's `SearXNGClient` queries `?format=json`).

## Opt in

```bash
./searxng-up.sh     # pulls the image, generates a secret, starts on 127.0.0.1:8080
```

Then in Summon, pick the **SearXNG** search provider (preset `http://127.0.0.1:8080`).

## Opt out

```bash
./searxng-down.sh
```

## Requirements

- Docker Desktop or colima (the script checks, and tells you if it's missing).

## Files

- `docker-compose.yml` — loopback-only SearXNG service.
- `settings.yml` — minimal override (JSON on, `use_default_settings: true`); a
  template — the real secret is generated into `runtime/settings.yml` (gitignored).
- `searxng-up.sh` / `searxng-down.sh` — bring up / tear down.
