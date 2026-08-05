#!/usr/bin/env bash
# Machine walkthrough — roles: user, agent, and non-shipping extension development fixtures.
# Native app has no browser surface; this is the walkthrough-nt equivalent for Summon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export HOME="${WALKTHROUGH_HOME:-$(mktemp -d)}"
export SUMMON_CONTAINER_DIR="${SUMMON_CONTAINER_DIR:-$HOME/container}"
echo "walkthrough: HOME=$HOME"
echo "walkthrough: SUMMON_CONTAINER_DIR=$SUMMON_CONTAINER_DIR"

swift build >/dev/null
BIN="$(swift build --show-bin-path)/summon-cli"

echo "=== role: human/user (CLI settings + search) ==="
"$BIN" version
"$BIN" settings set walkthrough.role human
"$BIN" search "2+2" | head -3
"$BIN" calc "3*3" | grep -q '^9$'
"$BIN" snippet add wt "walkthrough body" wt
"$BIN" snippet list | grep -q wt
"$BIN" clipboard ingest "walkthrough-clip"
"$BIN" clipboard list | grep -q walkthrough-clip
"$BIN" quicklink add WT https://example.com/wt wt
"$BIN" quicklink list | grep -q WT
"$BIN" actions app | grep -q app.open
"$BIN" search "lock kind:command" | grep -qi lock

echo "=== role: agent (same CLI, journals actor=agent) ==="
"$BIN" --actor agent settings set agent.walk true
"$BIN" ai status || true
"$BIN" --actor agent settings set agent.socket.enabled true || true
if "$BIN" settings get agent.socket.enabled 2>/dev/null | grep -q '^true$'; then
  echo "walkthrough: agent restricted setting applied directly" >&2
  exit 1
fi
"$BIN" window leftHalf | grep -q layout

echo "=== development seam: non-shipping extension fixtures ==="
swift test --filter FixtureHarnessTests >/dev/null

echo "=== role: system privacy (clipboard conceal) ==="
# Privacy unit path is covered by tests; assert binary still answers
"$BIN" clipboard list >/dev/null

echo "=== replay invariant ==="
swift test --filter JournalReplayTests >/dev/null

echo "walkthrough: ALL ROLES OK"
echo "walkthrough: log complete"
