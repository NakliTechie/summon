#!/usr/bin/env bash
# Validate unsigned local install, upgrade, rollback, uninstall, and zap under a temporary root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TEMP_ROOT="$(mktemp -d /tmp/summon-distribution.XXXXXX)"

cleanup() {
  case "$TEMP_ROOT" in
    /tmp/summon-distribution.*|/private/tmp/summon-distribution.*)
      rm -rf -- "$TEMP_ROOT"
      ;;
    *)
      echo "distribution-local: refused cleanup outside temporary root: $TEMP_ROOT" >&2
      ;;
  esac
}
trap cleanup EXIT

ARTIFACTS="$TEMP_ROOT/artifacts"
APPLICATIONS="$TEMP_ROOT/Applications"
TRASH="$TEMP_ROOT/Trash"
FAKE_HOME="$TEMP_ROOT/home"
CURRENT_OUT="$ARTIFACTS/current"
PREVIOUS_OUT="$ARTIFACTS/previous"
INSTALLED="$APPLICATIONS/Summon.app"
PREVIOUS_VERSION="0.5.0"

mkdir -p "$CURRENT_OUT" "$PREVIOUS_OUT" "$APPLICATIONS" "$TRASH" "$FAKE_HOME"

echo "distribution-local: build current ad-hoc app"
SUMMON_APP_OUT="$CURRENT_OUT" bash "$ROOT/packaging/macos/build-app.sh"
CURRENT_APP="$CURRENT_OUT/Summon.app"
test -x "$CURRENT_APP/Contents/MacOS/summon-app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CURRENT_APP/Contents/Info.plist")" = "$VERSION"
codesign --verify --deep --strict "$CURRENT_APP"

echo "distribution-local: create prior-version rollback fixture"
ditto "$CURRENT_APP" "$PREVIOUS_OUT/Summon.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PREVIOUS_VERSION" "$PREVIOUS_OUT/Summon.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PREVIOUS_VERSION" "$PREVIOUS_OUT/Summon.app/Contents/Info.plist"
codesign --force --deep --sign - "$PREVIOUS_OUT/Summon.app"
codesign --verify --deep --strict "$PREVIOUS_OUT/Summon.app"

echo "distribution-local: fresh install prior fixture"
ditto "$PREVIOUS_OUT/Summon.app" "$INSTALLED"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED/Contents/Info.plist")" = "$PREVIOUS_VERSION"

echo "distribution-local: upgrade to current artifact"
mv "$INSTALLED" "$TRASH/Summon-$PREVIOUS_VERSION.app"
ditto "$CURRENT_APP" "$INSTALLED"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED/Contents/Info.plist")" = "$VERSION"
codesign --verify --deep --strict "$INSTALLED"

echo "distribution-local: rollback to prior artifact"
mv "$INSTALLED" "$TRASH/Summon-$VERSION.app"
ditto "$PREVIOUS_OUT/Summon.app" "$INSTALLED"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED/Contents/Info.plist")" = "$PREVIOUS_VERSION"

echo "distribution-local: uninstall and explicit zap inside fake home"
mkdir -p "$FAKE_HOME/Library/Application Support/Summon"
mkdir -p "$FAKE_HOME/Library/Preferences"
printf '%s\n' fixture > "$FAKE_HOME/Library/Application Support/Summon/fixture.txt"
printf '%s\n' fixture > "$FAKE_HOME/Library/Preferences/tech.nakli.Summon.plist"
mv "$INSTALLED" "$TRASH/Summon-uninstalled.app"
test ! -e "$INSTALLED"
mv "$FAKE_HOME/Library/Application Support/Summon" "$TRASH/Application-Support-Summon"
mv "$FAKE_HOME/Library/Preferences/tech.nakli.Summon.plist" "$TRASH/tech.nakli.Summon.plist"
test ! -e "$FAKE_HOME/Library/Application Support/Summon"
test ! -e "$FAKE_HOME/Library/Preferences/tech.nakli.Summon.plist"

echo "distribution-local: PASS version=$VERSION prior=$PREVIOUS_VERSION"
