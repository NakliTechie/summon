#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

network_files="$({
    rg -l --glob '*.swift' \
        'URLSession|URLRequest|NWConnection|CFStream|Stream\.getStreamsToHost|dataTask|downloadTask|uploadTask' \
        Sources || true
} | LC_ALL=C sort)"
expected_network_files="Sources/SummonCore/WebSearch.swift"
if [[ "$network_files" != "$expected_network_files" ]]; then
    echo "network-sovereignty: undeclared direct network primitive"
    echo "$network_files"
    exit 1
fi

downloader_files="$({
    rg -l --glob '*.swift' 'huggingface-cli|/bin/hf"' Sources || true
} | LC_ALL=C sort)"
expected_downloader_files="Sources/SummonAI/L0ModelFetch.swift"
if [[ "$downloader_files" != "$expected_downloader_files" ]]; then
    echo "network-sovereignty: undeclared external downloader"
    echo "$downloader_files"
    exit 1
fi

if rg -n --glob '*.swift' '(/usr/bin/|/opt/homebrew/bin/|/usr/local/bin/)(curl|wget)' Sources; then
    echo "network-sovereignty: undeclared curl or wget execution path"
    exit 1
fi

rg -q 'authorization\?\.permits\(url: url, purpose: \.userWeb\)' \
    Sources/SummonCore/WebSearch.swift
rg -q 'authorization\?\.permits\(url: providerURL, purpose: \.userModelFetch\)' \
    Sources/SummonAI/L0ModelFetch.swift
rg -q 'NetworkSovereignty\.authorize' Sources/summon-cli/main.swift

swift test --filter NetworkSovereigntyTests

audit_log="$(mktemp /tmp/summon-egress-audit.XXXXXX)"
trap 'rm -f "$audit_log"' EXIT
export SUMMON_EGRESS_AUDIT_LOG="$audit_log"
bash scripts/verify-walkthrough.sh
if [[ -s "$audit_log" ]]; then
    echo "network-sovereignty: ambient walkthrough opened an authorized egress path"
    sed -n '1,20p' "$audit_log"
    exit 1
fi

echo "network-sovereignty: direct egress inventory constrained"
echo "network-sovereignty: 5 journal-bound authorization tests exercised"
echo "network-sovereignty: walkthrough emitted 0 egress audit records"
