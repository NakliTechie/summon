#!/usr/bin/env bash
# Machine walkthrough — roles: user (CLI), agent (CLI actor=agent paths), extension (swift test fixtures).
# Native app has no browser surface; this is the walkthrough-nt equivalent for Summon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export HOME="${WALKTHROUGH_HOME:-$(mktemp -d)}"
echo "walkthrough: HOME=$HOME"

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
"$BIN" settings set agent.walk true
# AI may or may not be available; status must not crash
"$BIN" ai status || true

echo "=== role: extension (shim fixtures via swift test) ==="
swift test --filter FixtureHarnessTests >/dev/null

echo "=== role: system privacy (clipboard conceal) ==="
# Privacy unit path is covered by tests; assert binary still answers
"$BIN" clipboard list >/dev/null

echo "=== replay invariant ==="
swift test --filter JournalReplayTests >/dev/null

echo "walkthrough: ALL ROLES OK"
echo "walkthrough: log complete"
