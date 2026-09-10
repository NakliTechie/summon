#!/usr/bin/env bash
# Bring up the Summon-managed SearXNG (opt-in current-web search provider).
#
# Runtime: prefers Apple's `container` (Apache-2.0, no Docker Desktop, Apple
# silicon + macOS 26+); falls back to Docker/colima elsewhere. Either way the
# service binds to 127.0.0.1 only, so Summon's loopback-only sovereignty guard
# holds. Port-resilient (reuses a running instance, else picks a free loopback
# port) and records the chosen URL so the app finds it. Idempotent. Never
# installs a runtime.
#
# Lifecycle order for the app-owned container `summon-searxng`, on both runtimes:
#   inspect → reuse if healthy → start if stopped → recreate only when the
#   existing instance fails its health check after a start, or when
#   SUMMON_SEARXNG_RECREATE=1 asks for an explicit rebuild.
# A stale recorded URL or a temporarily unhealthy service therefore never
# deletes the container on its own. On failure the runtime's log tail is printed.
set -euo pipefail
cd "$(dirname "$0")"

DISCOVERY="$HOME/.config/summon/searxng.url"
CONTAINER="summon-searxng"
IMAGE="docker.io/searxng/searxng:latest"
RECREATE="${SUMMON_SEARXNG_RECREATE:-0}"

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

wait_json() { # $1 = port, $2 = attempts (2s apart; default 40 = 80s)
  local attempts="${2:-40}"
  for _ in $(seq 1 "$attempts"); do
    curl -fsS "http://127.0.0.1:$1/search?q=test&format=json" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# Reuse a still-healthy instance regardless of which runtime started it.
if [ -f "$DISCOVERY" ] && [ "$RECREATE" != "1" ]; then
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

  # `container inspect` prints a JSON array; pull the two fields we need without
  # depending on jq/python being installed.
  container_state() { # running | stopped | missing
    local json
    json="$(container inspect "$CONTAINER" 2>/dev/null)" || { echo missing; return; }
    if printf '%s' "$json" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"running"'; then echo running; else echo stopped; fi
  }
  container_host_port() {
    container inspect "$CONTAINER" 2>/dev/null | grep -Eo '"hostPort"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -Eo '[0-9]+$' || true
  }
  container_logs_tail() { container logs -n 40 "$CONTAINER" 2>&1 | sed 's/^/  | /' >&2 || true; }

  state="$(container_state)"
  if [ "$RECREATE" = "1" ] && [ "$state" != "missing" ]; then
    echo "searxng: SUMMON_SEARXNG_RECREATE=1 — removing the existing $CONTAINER to rebuild it"
    container rm -f "$CONTAINER" >/dev/null 2>&1 || true
    state="missing"
  fi

  case "$state" in
    running)
      port="$(container_host_port)"
      if [ -n "$port" ] && wait_json "$port" 5; then
        echo "searxng: reusing running $CONTAINER"
        record "$port"; exit 0
      fi
      echo "searxng: $CONTAINER is running but its JSON API isn't answering on ${port:-?}; recreating it." >&2
      echo "searxng: last log lines before recreate:" >&2; container_logs_tail
      container rm -f "$CONTAINER" >/dev/null 2>&1 || true
      ;;
    stopped)
      echo "searxng: starting the stopped $CONTAINER…"
      if container start "$CONTAINER" >/dev/null 2>&1; then
        port="$(container_host_port)"
        if [ -n "$port" ] && wait_json "$port"; then record "$port"; exit 0; fi
      fi
      echo "searxng: $CONTAINER did not come back healthy after start; recreating it." >&2
      echo "searxng: last log lines before recreate:" >&2; container_logs_tail
      container rm -f "$CONTAINER" >/dev/null 2>&1 || true
      ;;
    missing) ;;
  esac

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
  echo "searxng: started on $PORT but the JSON API did not answer in 80s. Last log lines:" >&2
  container_logs_tail
  echo "searxng: the container is left in place for inspection ('container logs $CONTAINER')." >&2
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

docker_state() { # running | stopped | missing
  local status
  status="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" || { echo missing; return; }
  if [ "$status" = "running" ]; then echo running; else echo stopped; fi
}
docker_host_port() {
  docker port "$CONTAINER" 8080/tcp 2>/dev/null | sed -n 's/.*:\([0-9]\{2,5\}\)$/\1/p' | head -1 || true
}
docker_logs_tail() { docker logs --tail 40 "$CONTAINER" 2>&1 | sed 's/^/  | /' >&2 || true; }

state="$(docker_state)"
if [ "$RECREATE" = "1" ] && [ "$state" != "missing" ]; then
  echo "searxng: SUMMON_SEARXNG_RECREATE=1 — removing the existing $CONTAINER to rebuild it"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  state="missing"
fi

case "$state" in
  running)
    existing="$(docker_host_port)"
    if [ -n "$existing" ] && wait_json "$existing" 5; then
      echo "searxng: reusing running $CONTAINER"
      record "$existing"; exit 0
    fi
    echo "searxng: $CONTAINER is running but its JSON API isn't answering on ${existing:-?}; recreating it." >&2
    echo "searxng: last log lines before recreate:" >&2; docker_logs_tail
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    ;;
  stopped)
    echo "searxng: starting the stopped $CONTAINER…"
    if docker start "$CONTAINER" >/dev/null 2>&1; then
      existing="$(docker_host_port)"
      if [ -n "$existing" ] && wait_json "$existing"; then record "$existing"; exit 0; fi
    fi
    echo "searxng: $CONTAINER did not come back healthy after start; recreating it." >&2
    echo "searxng: last log lines before recreate:" >&2; docker_logs_tail
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    ;;
  missing) ;;
esac

ensure_settings
PORT="$(pick_port)" || { echo "searxng: could not find a free loopback port. Free one up and re-run." >&2; exit 4; }

echo "searxng: starting on 127.0.0.1:$PORT (pulling image if needed)…"
SUMMON_SEARXNG_PORT="$PORT" docker compose up -d

if wait_json "$PORT"; then record "$PORT"; exit 0; fi
echo "searxng: started on $PORT but the JSON API did not answer in 80s. Last log lines:" >&2
docker_logs_tail
echo "searxng: the container is left in place for inspection ('docker compose logs')." >&2
exit 1
