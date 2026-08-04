#!/usr/bin/env bash
# Build an ad-hoc-signed Summon.app from the SPM summon-app product.
# Developer ID / notarization: later (last in queue). This is the cask-local stand-in.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

VERSION="${SUMMON_VERSION:-0.6.0}"
OUT_DIR="${SUMMON_APP_OUT:-$ROOT/dist}"
APP="$OUT_DIR/Summon.app"
BIN_NAME="summon-app"

echo "build-app: swift build -c release"
swift build -c release --product summon-app

BIN="$(swift build -c release --show-bin-path)/$BIN_NAME"
test -x "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Stamp version only on the app copy — never mutate the source-controlled plist
PLIST_SRC="$ROOT/packaging/macos/Info.plist"
PLIST_DST="$APP/Contents/Info.plist"
cp "$PLIST_SRC" "$PLIST_DST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST_DST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST_DST"

cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"
chmod +x "$APP/Contents/MacOS/$BIN_NAME"

# Ad-hoc sign (identity "-") — enough for local cask install tests; not for distribution.
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP"

echo "build-app: wrote $APP"
echo "build-app: version $VERSION (ad-hoc signed)"
