#!/usr/bin/env bash
# Stop the Summon-managed SearXNG. Keeps runtime/settings.yml for next time.
# Matches searxng-up.sh: tries Apple `container` first, then Docker.
set -euo pipefail
cd "$(dirname "$0")"

CONTAINER="summon-searxng"
stopped=0

# Apple `container`: rm -f both stops the VM and reclaims its disk immediately.
if command -v container >/dev/null 2>&1 && container inspect "$CONTAINER" >/dev/null 2>&1; then
  container rm -f "$CONTAINER" >/dev/null 2>&1 || true
  echo "searxng: stopped (container instance removed; VM disk reclaimed)."
  stopped=1
fi

# Docker fallback.
if [ "$stopped" -eq 0 ] && command -v docker >/dev/null 2>&1; then
  if docker compose ps >/dev/null 2>&1; then
    docker compose down
    echo "searxng: stopped (docker)."
    stopped=1
  fi
fi

rm -f "$HOME/.config/summon/searxng.url"
[ "$stopped" -eq 0 ] && echo "searxng: nothing running to stop."
exit 0
