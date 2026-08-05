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
EXPECTED_VERSION="$(tr -d '[:space:]' < VERSION)"

echo "verify-walkthrough: building…"
swift build >/dev/null
BIN="$(swift build --show-bin-path)/summon-cli"

echo "== first-run: choice and launcher-seen policy =="
swift test --filter FirstRunLoginChoiceTests >/dev/null
echo "  ok: Decide Later, registration failure, and sheet timing regressions"

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
"$BIN" version | expect "version prints" "$EXPECTED_VERSION"

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

echo "== user role: window layout plan =="
WINDOW_PLAN="$("$BIN" window leftHalf)"
printf '%s\n' "$WINDOW_PLAN" | expect "window layout is named" "layout leftHalf"
printf '%s\n' "$WINDOW_PLAN" | expect "window geometry is deterministic" "frame 0,0 716x900"

echo "== agent actor: default-OFF admission =="
set +e
AGENT_DISABLED_OUTPUT="$("$BIN" --actor agent version 2>&1)"
AGENT_DISABLED_STATUS=$?
set -e
[ "$AGENT_DISABLED_STATUS" -eq 1 ] || fail "disabled agent CLI — wanted exit 1"
printf '%s\n' "$AGENT_DISABLED_OUTPUT" \
  | expect "disabled agent CLI is rejected" "agent CLI is disabled"

"$BIN" settings set agent.socket.enabled true >/dev/null
"$BIN" --actor agent version | expect "enabled agent CLI reaches version" "$EXPECTED_VERSION"

echo "== agent actor: restricted setting must STAGE, not apply directly =="
set +e
AGENT_STAGE_OUTPUT="$("$BIN" --actor agent settings set agent.socket.enabled false 2>&1)"
AGENT_STAGE_STATUS=$?
set -e
[ "$AGENT_STAGE_STATUS" -eq 3 ] || fail "agent stage exit — wanted 3, got $AGENT_STAGE_STATUS"
printf '%s\n' "$AGENT_STAGE_OUTPUT" | expect "agent reports staged outcome" "outcome staged proposalID="
if ! "$BIN" settings get agent.socket.enabled 2>/dev/null | grep -q "true"; then
  fail "agent applied restricted disable directly — propose-only guard broken"
fi
echo "  ok: agent restricted setting did not apply directly (staged)"

AGENT_SETTING_PROPOSAL="$(printf '%s\n' "$AGENT_STAGE_OUTPUT" | awk -F= '/outcome staged/{print $2}')"
set +e
AGENT_ACCEPT_OUTPUT="$("$BIN" --actor agent ai accept "$AGENT_SETTING_PROPOSAL" 2>&1)"
AGENT_ACCEPT_STATUS=$?
USER_ACCEPT_OUTPUT="$("$BIN" ai accept "$AGENT_SETTING_PROPOSAL" 2>&1)"
USER_ACCEPT_STATUS=$?
set -e
[ "$AGENT_ACCEPT_STATUS" -eq 1 ] || fail "agent self-accept — wanted exit 1"
[ "$USER_ACCEPT_STATUS" -eq 1 ] || fail "CLI agent-action accept — wanted exit 1"
printf '%s\n' "$AGENT_ACCEPT_OUTPUT" \
  | expect "agent cannot self-accept" "requires the interactive user actor"
printf '%s\n' "$USER_ACCEPT_OUTPUT" \
  | expect "CLI cannot cross human acceptance boundary" "only be accepted in Summon UI"
if ! "$BIN" settings get agent.socket.enabled 2>/dev/null | grep -q "true"; then
  fail "CLI acceptance changed the enabled setting"
fi
echo "  ok: staged agent setting remains pending for exact UI review"

echo "== agent actor: every module effect must STAGE =="
set +e
AGENT_RUN_OUTPUT="$("$BIN" --actor agent run app.open /Applications/AgentNeverOpened.app 2>&1)"
AGENT_RUN_STATUS=$?
set -e
[ "$AGENT_RUN_STATUS" -eq 3 ] || fail "agent module stage exit — wanted 3, got $AGENT_RUN_STATUS"
printf '%s\n' "$AGENT_RUN_OUTPUT" | expect "agent module reports staged outcome" "outcome staged proposalID="
AGENT_RUN_PROPOSAL="$(printf '%s\n' "$AGENT_RUN_OUTPUT" | awk -F= '/outcome staged/{print $2}')"
set +e
AGENT_REJECT_OUTPUT="$("$BIN" ai reject "$AGENT_RUN_PROPOSAL" 2>&1)"
AGENT_REJECT_STATUS=$?
set -e
[ "$AGENT_REJECT_STATUS" -eq 1 ] || fail "CLI agent-action reject — wanted exit 1"
printf '%s\n' "$AGENT_REJECT_OUTPUT" \
  | expect "agent proposal decisions stay in UI" "only be rejected in Summon UI"

echo "== agent actor: alternate mutation doors honor actor policy =="
set +e
AGENT_WEB_OUTPUT="$("$BIN" --actor agent web enable 2>&1)"
AGENT_WEB_STATUS=$?
set -e
[ "$AGENT_WEB_STATUS" -eq 3 ] || fail "agent web stage exit — wanted 3"
printf '%s\n' "$AGENT_WEB_OUTPUT" | expect "agent web enable stages" "outcome staged proposalID="
if "$BIN" settings get web.search.enabled 2>/dev/null | grep -q "true"; then
  fail "agent web enable persisted directly"
fi

"$BIN" ignore add com.example.Secret >/dev/null
set +e
AGENT_IGNORE_OUTPUT="$("$BIN" --actor agent ignore remove com.example.Secret 2>&1)"
AGENT_IGNORE_STATUS=$?
set -e
[ "$AGENT_IGNORE_STATUS" -eq 3 ] || fail "agent ignore removal stage exit — wanted 3"
printf '%s\n' "$AGENT_IGNORE_OUTPUT" \
  | expect "agent ignore removal stages" "outcome staged proposalID="
"$BIN" ignore list | expect "staged ignore removal preserves exclusion" "com.example.secret"

set +e
AGENT_WINDOW_OUTPUT="$("$BIN" --actor agent window leftHalf --apply 2>&1)"
AGENT_WINDOW_STATUS=$?
set -e
[ "$AGENT_WINDOW_STATUS" -eq 3 ] || fail "agent window stage exit — wanted 3"
printf '%s\n' "$AGENT_WINDOW_OUTPUT" \
  | expect "agent native window effect stages" "outcome staged proposalID="
echo "  ok: alternate agent mutation paths did not apply directly"

echo "== extension surface: omitted from R1 =="
set +e
EXTENSION_OUTPUT="$("$BIN" extension list 2>&1)"
EXTENSION_STATUS=$?
set -e
[ "$EXTENSION_STATUS" -eq 2 ] || fail "extension omission — wanted exit 2"
printf '%s\n' "$EXTENSION_OUTPUT" | expect "extension command is absent" "unknown command 'extension'"
if "$BIN" help | grep -qi extension; then fail "extension command leaked into help"; fi
echo "  ok: shipping CLI exposes no extension surface"

echo "== proposal decisions reject nonexistent IDs =="
MISSING_ACCEPT=00000000-0000-0000-0000-000000000001
MISSING_REJECT=00000000-0000-0000-0000-000000000002
if "$BIN" ai accept "$MISSING_ACCEPT" >/dev/null 2>&1; then fail "missing proposal accepted"; fi
if "$BIN" ai reject "$MISSING_REJECT" >/dev/null 2>&1; then fail "missing proposal rejected"; fi
echo "  ok: nonexistent proposal IDs exit nonzero"

echo "== agent actor: sensitive search requires a separate user grant =="
"$BIN" snippet add AgentPrivate agent-private-006-marker >/dev/null
"$BIN" clipboard ingest agent-private-006-marker >/dev/null
set +e
AGENT_SEARCH_OUTPUT="$("$BIN" --actor agent search agent-private-006-marker 2>&1)"
AGENT_SEARCH_STATUS=$?
set -e
if grep -qF "agent-private-006-marker" <<<"$AGENT_SEARCH_OUTPUT"; then
  fail "agent search exposed sensitive store data without a grant"
fi
[ "$AGENT_SEARCH_STATUS" -eq 1 ] || fail "ungranted sensitive search — wanted exit 1"
echo "  ok: ungranted agent search excludes sensitive stores"
"$BIN" settings set agent.search.sensitive.enabled true >/dev/null
"$BIN" --actor agent search agent-private-006-marker \
  | expect "granted agent search includes sensitive stores" "agent-private-006-marker"

echo "== agent actor: CLI reads carry typed journal attribution =="
"$BIN" --actor agent settings get port >/dev/null
"$BIN" --actor agent calc "2+2" >/dev/null
"$BIN" --actor agent actions app >/dev/null
"$BIN" --actor agent guide >/dev/null
"$BIN" --actor agent favorite list >/dev/null
JOURNAL_DB="$SUMMON_CONTAINER_DIR/summon.sqlite"
AGENT_CLI_AUDITS="$(/usr/bin/sqlite3 "$JOURNAL_DB" \
  "SELECT COUNT(*) FROM action_journal WHERE actor='agent' AND action_json LIKE '%\"name\":\"agent.cli\"%';")"
[ "$AGENT_CLI_AUDITS" -ge 5 ] || fail "agent CLI read audit count — wanted at least 5, got $AGENT_CLI_AUDITS"
AGENT_VERSION_AUDITS="$(/usr/bin/sqlite3 "$JOURNAL_DB" \
  "SELECT COUNT(*) FROM action_journal WHERE actor='agent' AND action_json LIKE '%\"name\":\"agent.version\"%';")"
[ "$AGENT_VERSION_AUDITS" -ge 1 ] || fail "agent version audit missing"
AGENT_SEARCH_AUDITS="$(/usr/bin/sqlite3 "$JOURNAL_DB" \
  "SELECT COUNT(*) FROM action_journal WHERE actor='agent' AND action_json LIKE '%\"name\":\"agent.search\"%';")"
[ "$AGENT_SEARCH_AUDITS" -ge 1 ] || fail "agent search audit missing"
echo "  ok: agent CLI reads are actor-tagged in the journal"

echo "== CLI actor boundary: internal actor labels are rejected =="
if "$BIN" --actor system version >/dev/null 2>&1; then fail "CLI accepted actor=system"; fi
if "$BIN" --actor ext:probe version >/dev/null 2>&1; then fail "CLI accepted actor=ext:probe"; fi
echo "  ok: CLI accepts only user and agent actors"

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
