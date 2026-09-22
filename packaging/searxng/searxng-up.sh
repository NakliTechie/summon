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
    curl -fsS --max-time 5 "http://127.0.0.1:$1/search?q=test&format=json" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# Reuse a still-healthy instance regardless of which runtime started it.
if [ -f "$DISCOVERY" ] && [ "$RECREATE" != "1" ]; then
  base="$(tr -d '\n' < "$DISCOVERY")"
  if [ -n "$base" ] && curl -fsS --max-time 5 "${base}search?q=test&format=json" >/dev/null 2>&1; then
    echo "searxng: reusing running instance ($base)"
    exit 0
  fi
fi

# ---- Pick a runtime ----
# Prefer Apple's `container` (arm64 + macOS 26+) — Apple-native, no Docker Desktop,
# no license — Summon's default runtime; fall back to an installed Docker.
# Override with SUMMON_SEARXNG_RUNTIME=container|docker to force one.
osmaj="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"; osmaj="${osmaj:-0}"
container_ok=false
if command -v container >/dev/null 2>&1 && [ "$(uname -m)" = "arm64" ] && [ "$osmaj" -ge 26 ] 2>/dev/null; then
  container_ok=true
fi

RUNTIME="${SUMMON_SEARXNG_RUNTIME:-}"
if [ -n "$RUNTIME" ]; then
  command -v "$RUNTIME" >/dev/null 2>&1 || { echo "searxng: forced runtime '$RUNTIME' not found." >&2; exit 2; }
elif [ "$container_ok" = true ]; then
  RUNTIME="container"
elif command -v docker >/dev/null 2>&1; then
  RUNTIME="docker"
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
  # After a create conflict the winner's container can take a moment to become
  # inspectable; poll briefly before deciding it does not exist.
  container_wait_visible() { for _ in $(seq 1 10); do [ "$(container_state)" != "missing" ] && return 0; sleep 1; done; return 1; }

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
  # Each container is its own lightweight VM, so the Docker path's cap-drop
  # hardening isn't needed here — VM isolation substitutes for it.
  if ! create_out="$(container run -d --name "$CONTAINER" \
      -p "127.0.0.1:${PORT}:8080" \
      -v "$(pwd)/runtime/settings.yml:/etc/searxng/settings.yml" \
      -e "SEARXNG_BASE_URL=http://127.0.0.1:${PORT}/" \
      "$IMAGE" 2>&1)"; then
    # Two invocations can race to create the same name; the loser sees a name
    # conflict. Treat "someone else created it" as reuse, not as failure.
    if container_wait_visible; then
      echo "searxng: another invocation created $CONTAINER first; reusing it."
      port="$(container_host_port)"
      if [ -n "$port" ] && wait_json "$port"; then record "$port"; exit 0; fi
    fi
    echo "searxng: could not create $CONTAINER:" >&2
    printf '%s\n' "$create_out" | sed 's/^/  | /' >&2
    exit 1
  fi

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

docker_state() { # running | paused | stopped | missing
  local status
  status="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" || { echo missing; return; }
  case "$status" in
    running) echo running ;;
    paused) echo paused ;;   # frozen, not stopped: `docker start` would fail and provoke a needless recreate
    *) echo stopped ;;
  esac
}
docker_host_port() {
  # The configured binding is present from creation on, even before the container
  # runs; the live mapping (`docker port`) only exists once it is up.
  docker inspect -f '{{(index (index .HostConfig.PortBindings "8080/tcp") 0).HostPort}}' "$CONTAINER" 2>/dev/null \
    | grep -Eo '^[0-9]{2,5}$' | head -1 || true
}
docker_logs_tail() { docker logs --tail 40 "$CONTAINER" 2>&1 | sed 's/^/  | /' >&2 || true; }
# After a create conflict the winner's container can take a moment to become
# inspectable; poll briefly before deciding it does not exist.
docker_wait_visible() { for _ in $(seq 1 10); do [ "$(docker_state)" != "missing" ] && return 0; sleep 1; done; return 1; }

state="$(docker_state)"
if [ "$RECREATE" = "1" ] && [ "$state" != "missing" ]; then
  echo "searxng: SUMMON_SEARXNG_RECREATE=1 — removing the existing $CONTAINER to rebuild it"
  docker rm -f -v "$CONTAINER" >/dev/null 2>&1 || true
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
    docker rm -f -v "$CONTAINER" >/dev/null 2>&1 || true
    ;;
  paused)
    # A paused container is intact; unpausing restores it in a second where a
    # start would fail and a recreate would take minutes.
    echo "searxng: unpausing $CONTAINER…"
    if docker unpause "$CONTAINER" >/dev/null 2>&1; then
      existing="$(docker_host_port)"
      if [ -n "$existing" ] && wait_json "$existing" 10; then record "$existing"; exit 0; fi
    fi
    echo "searxng: $CONTAINER did not answer after unpause; recreating it." >&2
    echo "searxng: last log lines before recreate:" >&2; docker_logs_tail
    docker rm -f -v "$CONTAINER" >/dev/null 2>&1 || true
    ;;
  stopped)
    echo "searxng: starting the stopped $CONTAINER…"
    if docker start "$CONTAINER" >/dev/null 2>&1; then
      existing="$(docker_host_port)"
      if [ -n "$existing" ] && wait_json "$existing"; then record "$existing"; exit 0; fi
    fi
    echo "searxng: $CONTAINER did not come back healthy after start; recreating it." >&2
    echo "searxng: last log lines before recreate:" >&2; docker_logs_tail
    docker rm -f -v "$CONTAINER" >/dev/null 2>&1 || true
    ;;
  missing) ;;
esac

ensure_settings
PORT="$(pick_port)" || { echo "searxng: could not find a free loopback port. Free one up and re-run." >&2; exit 4; }

echo "searxng: starting on 127.0.0.1:$PORT (pulling image if needed)…"
# Plain `docker run`: no dependency on the compose CLI plugin, which lives under
# the account's ~/.docker and disappears whenever HOME is redirected. Loopback
# bind, read-only settings mount, drop all capabilities but the three SearXNG
# needs, bounded logs, and restart-unless-stopped so Docker restores it itself.
if ! create_out="$(docker run -d --name "$CONTAINER" \
    --restart unless-stopped \
    --cap-drop ALL --cap-add CHOWN --cap-add SETGID --cap-add SETUID \
    --log-driver json-file --log-opt max-size=1m --log-opt max-file=1 \
    -p "127.0.0.1:${PORT}:8080" \
    -v "$(pwd)/runtime/settings.yml:/etc/searxng/settings.yml:ro" \
    -e "SEARXNG_BASE_URL=http://127.0.0.1:${PORT}/" \
    "$IMAGE" 2>&1)"; then
  # Two invocations can race to create the same name; the loser sees a name
  # conflict. Treat "someone else created it" as reuse, not as failure.
  if docker_wait_visible; then
    echo "searxng: another invocation created $CONTAINER first; reusing it."
    existing="$(docker_host_port)"
    if [ -n "$existing" ] && wait_json "$existing"; then record "$existing"; exit 0; fi
  fi
  echo "searxng: could not create $CONTAINER:" >&2
  printf '%s\n' "$create_out" | sed 's/^/  | /' >&2
  exit 1
fi

if wait_json "$PORT"; then record "$PORT"; exit 0; fi
echo "searxng: started on $PORT but the JSON API did not answer in 80s. Last log lines:" >&2
docker_logs_tail
echo "searxng: the container is left in place for inspection ('docker logs $CONTAINER')." >&2
exit 1
