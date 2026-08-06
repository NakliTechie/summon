#!/usr/bin/env bash
# Bring up the Summon-managed SearXNG (opt-in current-web search provider).
# Idempotent. Requires Docker (we never install it). Loopback-only, JSON enabled.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v docker >/dev/null 2>&1; then
  echo "SearXNG needs Docker, which isn't installed." >&2
  echo "Install Docker Desktop (https://docker.com) or colima, then re-run this." >&2
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but not running. Start Docker (or 'colima start'), then re-run." >&2
  exit 3
fi

# Generate a settings file with a fresh secret on first run (kept out of git).
mkdir -p runtime
if [ ! -f runtime/settings.yml ]; then
  secret="$( (command -v openssl >/dev/null && openssl rand -hex 32) || head -c32 /dev/urandom | xxd -p -c 64 )"
  sed "s/__SUMMON_SEARXNG_SECRET__/${secret}/" settings.yml > runtime/settings.yml
  echo "searxng: generated runtime/settings.yml with a fresh secret"
fi

echo "searxng: pulling + starting (127.0.0.1:8080)…"
docker compose up -d

# Wait for the JSON API to answer.
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:8080/search?q=test&format=json" >/dev/null 2>&1; then
    echo "searxng: UP and answering JSON at http://127.0.0.1:8080/"
    echo "searxng: in Summon, pick the SearXNG provider (baseURL http://127.0.0.1:8080)."
    exit 0
  fi
  sleep 2
done
echo "searxng: started but the JSON API did not answer in 60s — check 'docker compose logs'." >&2
exit 1
