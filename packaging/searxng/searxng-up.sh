#!/usr/bin/env bash
# Bring up the Summon-managed SearXNG (opt-in current-web search provider).
#
# Runtime: prefers Apple's `container` (Apache-2.0, no Docker Desktop, Apple
# silicon + macOS 26+); falls back to Docker/colima elsewhere. Either way the
# service binds to 127.0.0.1 only, so Summon's loopback-only sovereignty guard
# holds. Port-resilient (reuses a running instance, else picks a free loopback
# port) and records the chosen URL so the app finds it. Idempotent. Never
# installs a runtime.
set -euo pipefail
cd "$(dirname "$0")"

DISCOVERY="$HOME/.config/summon/searxng.url"
CONTAINER="summon-searxng"
IMAGE="docker.io/searxng/searxng:latest"

port_free() { ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

record() {
  mkdir -p "$(dirname "$DISCOVERY")"
  printf 'http://127.0.0.1:%s/\n' "$1" > "$DISCOVERY"
  echo "searxng: UP at http://127.0.0.1:$1/  (recorded in $DISCOVERY)"
  echo "searxng: Summon will use it automatically; no port to configure."
}

ensure_settings() {
  mkdir -p runtime
  if [ ! -f runtime/settings.yml ]; then
    secret="$( (command -v openssl >/dev/null && openssl rand -hex 32) || head -c32 /dev/urandom | xxd -p -c 64 )"
    sed "s/__SUMMON_SEARXNG_SECRET__/${secret}/" settings.yml > runtime/settings.yml
  fi
}

pick_port() {
  for p in $(seq 8080 8099); do port_free "$p" && { echo "$p"; return 0; }; done
  for _ in $(seq 1 30); do
    p=$(( (RANDOM % 20000) + 20000 ))
    port_free "$p" && { echo "$p"; return 0; }
  done
  return 1
}

wait_json() { # $1 = port
  for _ in $(seq 1 40); do
    curl -fsS "http://127.0.0.1:$1/search?q=test&format=json" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# Reuse a still-healthy instance regardless of which runtime started it.
if [ -f "$DISCOVERY" ]; then
  base="$(tr -d '\n' < "$DISCOVERY")"
  if [ -n "$base" ] && curl -fsS "${base}search?q=test&format=json" >/dev/null 2>&1; then
    echo "searxng: reusing running instance ($base)"
    exit 0
  fi
fi

# ---- Pick a runtime ----
# Reuse an installed Docker if it's already present; otherwise use Apple's
# `container` (arm64 + macOS 26+) — Apple-native, no Docker Desktop, no license.
# Override with SUMMON_SEARXNG_RUNTIME=container|docker to force one.
osmaj="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"; osmaj="${osmaj:-0}"
container_ok=false
if command -v container >/dev/null 2>&1 && [ "$(uname -m)" = "arm64" ] && [ "$osmaj" -ge 26 ] 2>/dev/null; then
  container_ok=true
fi

RUNTIME="${SUMMON_SEARXNG_RUNTIME:-}"
if [ -n "$RUNTIME" ]; then
  command -v "$RUNTIME" >/dev/null 2>&1 || { echo "searxng: forced runtime '$RUNTIME' not found." >&2; exit 2; }
elif command -v docker >/dev/null 2>&1; then
  RUNTIME="docker"
elif [ "$container_ok" = true ]; then
  RUNTIME="container"
else
  echo "SearXNG needs a container runtime, which isn't installed." >&2
  if [ "$(uname -m)" = "arm64" ] && [ "$osmaj" -ge 26 ] 2>/dev/null; then
    echo "Recommended:  brew install container   (Apple-native, no Docker Desktop)" >&2
  fi
  echo "Or install Docker Desktop (https://docker.com) / colima, then re-run this." >&2
  exit 2
fi
echo "searxng: runtime = $RUNTIME"

# ============================ Apple `container` path ============================
if [ "$RUNTIME" = "container" ]; then
  # Bring up the container system; first run fetches a small guest kernel.
  if ! container system status >/dev/null 2>&1; then
    echo "searxng: starting the container runtime (first run downloads a guest kernel)…" >&2
    container system start </dev/null >/dev/null 2>&1 || true
    container system kernel set --recommended >/dev/null 2>&1 || true
    container system start </dev/null >/dev/null 2>&1 || true
  fi
  if ! container system status >/dev/null 2>&1; then
    echo "searxng: the container runtime didn't come up. Run 'container system start' once, then re-run this." >&2
    exit 3
  fi

  # Clear any stale/stopped instance of the same name before starting fresh.
  container rm -f "$CONTAINER" >/dev/null 2>&1 || true

  ensure_settings
  PORT="$(pick_port)" || { echo "searxng: could not find a free loopback port. Free one up and re-run." >&2; exit 4; }

  echo "searxng: starting on 127.0.0.1:$PORT via container (pulling image if needed)…"
  # Each container is its own lightweight VM, so the compose cap_drop/cap_add
  # hardening isn't needed here — VM isolation substitutes for it.
  container run -d --name "$CONTAINER" \
    -p "127.0.0.1:${PORT}:8080" \
    -v "$(pwd)/runtime/settings.yml:/etc/searxng/settings.yml" \
    -e "SEARXNG_BASE_URL=http://127.0.0.1:${PORT}/" \
    "$IMAGE" >/dev/null

  if wait_json "$PORT"; then record "$PORT"; exit 0; fi
  echo "searxng: started on $PORT but the JSON API did not answer in 80s — check 'container logs $CONTAINER'." >&2
  exit 1
fi

# ================================ Docker path ==================================
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

# Reuse a running instance rather than starting a second one on a new port.
if docker ps --filter "name=^${CONTAINER}$" --filter "status=running" --format '{{.Names}}' \
    | grep -q "$CONTAINER"; then
  existing="$(docker port "$CONTAINER" 2>/dev/null | sed -n 's/.*:\([0-9]\{2,5\}\)$/\1/p' | head -1)"
  if [ -n "${existing:-}" ]; then
    record "$existing"
    exit 0
  fi
fi

ensure_settings
PORT="$(pick_port)" || { echo "searxng: could not find a free loopback port. Free one up and re-run." >&2; exit 4; }

echo "searxng: starting on 127.0.0.1:$PORT (pulling image if needed)…"
SUMMON_SEARXNG_PORT="$PORT" docker compose up -d

if wait_json "$PORT"; then record "$PORT"; exit 0; fi
echo "searxng: started on $PORT but the JSON API did not answer in 80s — check 'docker compose logs'." >&2
exit 1
