#!/usr/bin/env bash
#
# verify-walkthrough.sh — drive summon-cli through each role's core journey and
# exit non-zero on the first failure. This is the runtime counterpart to the
# unit suite: it proves the real binary still walks the happy paths a user and
# an agent take.
#
# Hermetic: SUMMON_CONTAINER_DIR points the store at a throwaway dir, so a run
# never touches the user's real ~/Library/Application Support/Summon store (the
# Application Support API ignores $HOME, so that override is the only isolation
# that actually holds).
#
# Rerun with:  bash scripts/verify-walkthrough.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "verify-walkthrough: building…"
swift build >/dev/null
BIN="$(swift build --show-bin-path)/summon-cli"

WORK="$(mktemp -d)"
export SUMMON_CONTAINER_DIR="$WORK/container"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
# expect <description> <substring> ; reads the command output from stdin
expect() {
  local desc="$1" want="$2" got
  got="$(cat)"
  grep -qF -- "$want" <<<"$got" || fail "$desc — wanted '$want', got: ${got:-<empty>}"
  echo "  ok: $desc"
}

echo "== user role: launch =="
"$BIN" version | expect "version prints" "0.6.0"

echo "== user role: calculator (C1 — big number must not crash) =="
"$BIN" calc "2+2"                  | expect "calc 2+2" "4"
"$BIN" calc "3*(4+5)"             | expect "calc precedence" "27"
"$BIN" calc "9223372036854775807" | expect "C1 overflow returns a value, no abort" "e+18"

echo "== user role: settings (H1 — big number must not crash) =="
"$BIN" settings set port 8080 >/dev/null
"$BIN" settings get port                          | expect "settings round-trip" "8080"
"$BIN" settings set big 9223372036854775807       | expect "H1 overflow set, no abort" "ok"

echo "== user role: clipboard =="
"$BIN" clipboard ingest "verify-clip" >/dev/null
"$BIN" clipboard list | expect "clipboard list shows ingest" "verify-clip"
CID="$("$BIN" clipboard list | grep verify-clip | head -1 | awk '{print $1}')"
"$BIN" clipboard delete "$CID" >/dev/null
if "$BIN" clipboard list | grep -q "verify-clip"; then fail "clipboard delete left the row"; fi
echo "  ok: clipboard delete removes the row"

echo "== user role: quicklink =="
"$BIN" quicklink add Example https://example.com ex >/dev/null
"$BIN" quicklink list | expect "quicklink list" "Example"

echo "== user role: actions =="
"$BIN" actions app | expect "actions app" "app.open"

echo "== agent actor: restricted setting must STAGE, not apply directly =="
"$BIN" --actor agent settings set agent.socket.enabled true >/dev/null 2>&1 || true
if "$BIN" settings get agent.socket.enabled 2>/dev/null | grep -q "true"; then
  fail "agent applied a restricted setting directly — propose-only guard broken"
fi
echo "  ok: agent restricted setting did not apply directly (staged)"

echo "== first-run: a fresh container must not crash =="
FRESH="$WORK/fresh"
SUMMON_CONTAINER_DIR="$FRESH" "$BIN" actions app     | expect "first-run actions" "app.open"
SUMMON_CONTAINER_DIR="$FRESH" "$BIN" clipboard list >/dev/null
echo "  ok: first-run empty clipboard does not crash"

echo "== isolation: the run must not have touched the real store =="
REAL="$HOME/Library/Application Support/Summon/summon.sqlite"
if [ -f "$REAL" ] && strings "$REAL" 2>/dev/null | grep -q "verify-clip"; then
  fail "SUMMON_CONTAINER_DIR isolation broken — 'verify-clip' leaked into the real store"
fi
echo "  ok: real store untouched"

echo "verify-walkthrough: PASS"
