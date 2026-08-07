#!/usr/bin/env bash
# Regenerate the Summon guide: capture the drawn product, then build the searchable HTML.
#
# Summon is a native macOS app with no browsable web surface, so its authoritative
# visual is docs/summon-ux-reference-006.html — a self-contained mockup. capture.py
# screenshots its sections (no dev server needed); build_index.py assembles the
# single-file guide/index.html. Source of truth is the generator's data (route-plan
# in capture.py, captions in build_index.py) — never hand-edit index.html.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 guide/capture.py
python3 guide/build_index.py
echo "guide: guide/index.html"
