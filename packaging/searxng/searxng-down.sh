#!/usr/bin/env bash
# Stop the Summon-managed SearXNG. Keeps runtime/settings.yml for next time.
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not installed — nothing to stop." >&2
  exit 0
fi
docker compose down
echo "searxng: stopped."
