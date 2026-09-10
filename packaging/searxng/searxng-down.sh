#!/usr/bin/env bash
# Disable or remove the Summon-managed SearXNG. Matches searxng-up.sh: tries
# Apple `container` first, then Docker. Only ever touches the app-owned
# container `summon-searxng`; never stops the shared runtime itself.
#
#   searxng-down.sh                  Disable: stop the service, keep the container,
#                                    settings and data for a fast re-enable.
#   searxng-down.sh --remove         Remove local backend: delete the container and
#                                    the recorded URL. The image stays (layers can be
#                                    shared with other containers).
#   searxng-down.sh --remove --purge-image
#                                    Also delete the SearXNG image.
set -euo pipefail

usage() {
  cat <<'EOF'
searxng-down.sh — disable or remove the Summon-managed SearXNG (app-owned container
`summon-searxng` only; the shared runtime is never stopped).

  searxng-down.sh                  Disable: stop the service, keep the container,
                                   settings and data for a fast re-enable.
  searxng-down.sh --remove         Remove local backend: delete the container and
                                   the recorded URL. The image stays (layers can be
                                   shared with other containers).
  searxng-down.sh --remove --purge-image
                                   Also delete the SearXNG image.
EOF
}

# Parse arguments before changing directory so `--help` works from any cwd.
CONTAINER="summon-searxng"
IMAGE="docker.io/searxng/searxng:latest"
DISCOVERY="$HOME/.config/summon/searxng.url"
MODE="stop"
PURGE_IMAGE=0
for arg in "$@"; do
  case "$arg" in
    --remove) MODE="remove" ;;
    --purge-image) PURGE_IMAGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "searxng-down: unknown option '$arg'" >&2; exit 2 ;;
  esac
done
if [ "$PURGE_IMAGE" -eq 1 ] && [ "$MODE" != "remove" ]; then
  echo "searxng-down: --purge-image requires --remove" >&2; exit 2
fi

handled=0

# Apple `container`. `stop` leaves the container and its VM disk in place; `rm -f`
# reclaims the disk. Both use the runtime's own commands, never its storage dirs.
if command -v container >/dev/null 2>&1 && container system status >/dev/null 2>&1 \
   && container inspect "$CONTAINER" >/dev/null 2>&1; then
  if [ "$MODE" = "stop" ]; then
    container stop "$CONTAINER" >/dev/null 2>&1 || true
    echo "searxng: disabled (container stopped; instance, settings and data kept)."
  else
    container rm -f "$CONTAINER" >/dev/null 2>&1 || true
    echo "searxng: removed (container instance deleted; VM disk reclaimed)."
    if [ "$PURGE_IMAGE" -eq 1 ]; then
      container image rm "$IMAGE" >/dev/null 2>&1 && echo "searxng: image removed." \
        || echo "searxng: image kept (still referenced, or already gone)."
    fi
  fi
  handled=1
fi

# Docker fallback.
if [ "$handled" -eq 0 ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
   && docker inspect "$CONTAINER" >/dev/null 2>&1; then
  if [ "$MODE" = "stop" ]; then
    docker stop "$CONTAINER" >/dev/null 2>&1 || true
    echo "searxng: disabled (docker container stopped; instance, settings and data kept)."
  else
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    echo "searxng: removed (docker container deleted)."
    if [ "$PURGE_IMAGE" -eq 1 ]; then
      docker image rm searxng/searxng:latest >/dev/null 2>&1 && echo "searxng: image removed." \
        || echo "searxng: image kept (still referenced, or already gone)."
    fi
  fi
  handled=1
fi

if [ "$MODE" = "remove" ]; then
  rm -f "$DISCOVERY"
fi
[ "$handled" -eq 0 ] && echo "searxng: no app-owned instance found on any running runtime."
exit 0
