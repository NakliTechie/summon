#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

canonical="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$canonical" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "version-consistency: VERSION is not a semantic version"
    exit 1
fi

swift_version="$(sed -n 's/.*public static let string = "\([^"]*\)".*/\1/p' Sources/SummonCore/SummonCore.swift)"
plist_short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/macos/Info.plist)"
plist_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' packaging/macos/Info.plist)"
cask_version="$(sed -n 's/^[[:space:]]*version "\([^"]*\)"/\1/p' packaging/homebrew/Casks/summon.rb)"

for pair in \
    "SummonVersion:$swift_version" \
    "CFBundleShortVersionString:$plist_short" \
    "CFBundleVersion:$plist_build" \
    "Homebrew cask:$cask_version"; do
    label="${pair%%:*}"
    value="${pair#*:}"
    if [[ "$value" != "$canonical" ]]; then
        echo "version-consistency: $label=$value differs from VERSION=$canonical"
        exit 1
    fi
done

echo "version-consistency: VERSION=$canonical across Swift, plist, and cask"
