#!/usr/bin/env bash
# Bring up the Summon-managed SearXNG (opt-in current-web search provider).
# Port-resilient: reuses a running instance, else picks whatever loopback port
# is free (your machine may already hold 8080). Records the chosen URL so the
# app finds it regardless of port. Idempotent. Requires Docker; never installs it.
set -euo pipefail
cd "$(dirname "$0")"

DISCOVERY="$HOME/.config/summon/searxng.url"
CONTAINER="summon-searxng"

if ! command -v docker >/dev/null 2>&1; then
  echo "SearXNG needs Docker, which isn't installed." >&2
  echo "Install Docker Desktop (https://docker.com) or colima, then re-run this." >&2
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  echo "searxng: Docker daemon not running — starting it…" >&2
  # Bring the daemon up ourselves (Docker Desktop, else colima) instead of failing.
  if open -a Docker >/dev/null 2>&1 || open -a "Docker Desktop" >/dev/null 2>&1; then
    :
  elif command -v colima >/dev/null 2>&1; then
    colima start >/dev/null 2>&1 || true
  fi
  for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    sleep 2
  done
  if ! docker info >/dev/null 2>&1; then
    echo "searxng: Docker didn't come up in ~120s. Open Docker Desktop manually, then re-run." >&2
    exit 3
  fi
  echo "searxng: Docker daemon is up."
fi

port_free() { ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

record() {
  mkdir -p "$(dirname "$DISCOVERY")"
  printf 'http://127.0.0.1:%s/\n' "$1" > "$DISCOVERY"
  echo "searxng: UP at http://127.0.0.1:$1/  (recorded in $DISCOVERY)"
  echo "searxng: Summon will use it automatically; no port to configure."
}

# Reuse a running instance rather than starting a second one on a new port.
if docker ps --filter "name=^${CONTAINER}$" --filter "status=running" --format '{{.Names}}' \
    | grep -q "$CONTAINER"; then
  existing="$(docker port "$CONTAINER" 2>/dev/null | sed -n 's/.*:\([0-9]\{2,5\}\)$/\1/p' | head -1)"
  if [ -n "${existing:-}" ]; then
    record "$existing"
    exit 0
  fi
fi

# Pick a free loopback port: 8080..8099, then a high-range fallback.
PORT=""
for p in $(seq 8080 8099); do
  if port_free "$p"; then PORT="$p"; break; fi
done
if [ -z "$PORT" ]; then
  for _ in $(seq 1 30); do
    p=$(( (RANDOM % 20000) + 20000 ))
    if port_free "$p"; then PORT="$p"; break; fi
  done
fi
if [ -z "$PORT" ]; then
  echo "searxng: could not find a free loopback port. Free one up and re-run." >&2
  exit 4
fi

# Fresh secret on first run (kept out of git).
mkdir -p runtime
if [ ! -f runtime/settings.yml ]; then
  secret="$( (command -v openssl >/dev/null && openssl rand -hex 32) || head -c32 /dev/urandom | xxd -p -c 64 )"
  sed "s/__SUMMON_SEARXNG_SECRET__/${secret}/" settings.yml > runtime/settings.yml
fi

echo "searxng: starting on 127.0.0.1:$PORT (pulling image if needed)…"
SUMMON_SEARXNG_PORT="$PORT" docker compose up -d

for i in $(seq 1 40); do
  if curl -fsS "http://127.0.0.1:$PORT/search?q=test&format=json" >/dev/null 2>&1; then
    record "$PORT"
    exit 0
  fi
  sleep 2
done
echo "searxng: started on $PORT but the JSON API did not answer in 80s — check 'docker compose logs'." >&2
exit 1
