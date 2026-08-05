# Summon — Makefile wrappers (handoff §1).
# Gate: `make verify` is the merge definition of done.

SHELL := /bin/bash
SWIFT := swift
BUILD_FLAGS :=
# Removability: SUMMON_AI_ENABLED=0 make build  (omits SummonAI product)
export SUMMON_AI_ENABLED ?= 1

.PHONY: build test verify release clean cli-e2e lint removability extension-omission app cask-local distribution-local l1-probe walkthrough latency-soft latency-hard network-sovereignty version-consistency help

help:
	@echo "Targets: build test verify app cask-local l1-probe walkthrough release clean …"

walkthrough:
	bash scripts/verify-walkthrough.sh

network-sovereignty:
	bash scripts/verify-network-sovereignty.sh

version-consistency:
	bash scripts/verify-version.sh

# Live Apple Foundation Models probe on the designated M4 host (READY-l1-hardware).
l1-probe: build
	@set -euo pipefail; \
	SUMMON_RUN_L1_LIVE=1 $(SWIFT) test $(BUILD_FLAGS) --filter L1LiveProbeTests; \
	TMP=$$(mktemp -d /tmp/summon-l1-probe.XXXXXX); \
	export SUMMON_CONTAINER_DIR="$$TMP/container"; \
	BIN="$$($(SWIFT) build $(BUILD_FLAGS) --show-bin-path)/summon-cli"; \
	echo "l1-probe: ai status"; \
	"$$BIN" ai status; \
	echo "l1-probe: ai complete (staged)"; \
	"$$BIN" ai complete "Reply with exactly one word: pong"; \
	echo "l1-probe: live availability and completion exercised"

# Ad-hoc Summon.app under dist/ (no Developer ID).
app:
	bash packaging/macos/build-app.sh

# Local Homebrew cask dry-run against ad-hoc app zip (handoff READY-cask).
cask-local: app
	bash packaging/homebrew/test-local-cask.sh

distribution-local:
	bash scripts/verify-local-distribution.sh

build:
	$(SWIFT) build $(BUILD_FLAGS)

test:
	$(SWIFT) test $(BUILD_FLAGS)

lint:
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint --strict --no-cache --config .swiftlint.yml; \
	else \
		echo "lint: swiftlint not installed (brew install swiftlint) — FAIL"; \
		exit 1; \
	fi

# Handoff §8.4 — full suite build without SummonAI product.
removability:
	@set -euo pipefail; \
	SUMMON_AI_ENABLED=0 $(SWIFT) package dump-package >/tmp/summon-pkg-noai.json; \
	if python3 -c "import json;d=json.load(open('/tmp/summon-pkg-noai.json')); names=[p['name'] for p in d['products']]; assert 'SummonAI' not in names, names"; then \
		echo "removability: SummonAI product absent when SUMMON_AI_ENABLED=0"; \
	else \
		echo "removability: FAIL SummonAI still present"; exit 1; \
	fi; \
	SUMMON_AI_ENABLED=0 $(SWIFT) build $(BUILD_FLAGS); \
	SUMMON_AI_ENABLED=0 $(SWIFT) test $(BUILD_FLAGS); \
	echo "removability: build+test green without SummonAI"

# R1 product decision: the development shim remains testable but is absent from shipping executables.
extension-omission: build
	@set -euo pipefail; \
	PACKAGE_JSON=$$(mktemp /tmp/summon-package.XXXXXX); \
	$(SWIFT) package dump-package >"$$PACKAGE_JSON"; \
	python3 -c "import json,sys; d=json.load(open(sys.argv[1])); t={x['name']:x for x in d['targets']}; assert 'SummonShim' not in str(t['summon-cli']['dependencies']); assert 'SummonShim' not in str(t['summon-app']['dependencies'])" "$$PACKAGE_JSON"; \
	BIN="$$($(SWIFT) build $(BUILD_FLAGS) --show-bin-path)"; \
	for PRODUCT in summon-cli summon-app; do \
		if /usr/bin/otool -L "$$BIN/$$PRODUCT" | grep -q JavaScriptCore; then \
			echo "extension-omission: FAIL $$PRODUCT links JavaScriptCore"; exit 1; \
		fi; \
	done; \
	echo "extension-omission: shipping executables omit SummonShim and JavaScriptCore"

# Merge gate: hard latency, network sovereignty, and version consistency run beside the product suites.
verify: test cli-e2e lint removability extension-omission walkthrough network-sovereignty version-consistency latency-hard
	@echo "verify: unit+integration + journal-replay + cli-e2e + shim + lint + removability + extension-omission + walkthrough + network-sovereignty + version-consistency + latency-hard"

# Soft p95 sample (Batch F) — always exit 0; prints budget comparison.
latency-soft: build
	@set -euo pipefail; \
	BIN="$$($(SWIFT) build $(BUILD_FLAGS) --show-bin-path)/summon-cli"; \
	"$$BIN" latency 50; \
	echo "latency-soft: probe only (not a hard fail)"

latency-hard: build
	@set -euo pipefail; \
	BIN="$$($(SWIFT) build $(BUILD_FLAGS) --show-bin-path)/summon-cli"; \
	"$$BIN" latency live 50

# One action end-to-end via the real CLI binary (C-spine).
cli-e2e: build
	@set -euo pipefail; \
	TMP=$$(mktemp -d); \
	export HOME="$$TMP"; \
	export SUMMON_CONTAINER_DIR="$$TMP/container"; \
	BIN="$$($(SWIFT) build $(BUILD_FLAGS) --show-bin-path)/summon-cli"; \
	"$$BIN" version | grep -E -q '.'; \
	"$$BIN" settings set cspine.cli true; \
	OUT=$$("$$BIN" settings get cspine.cli); \
	test "$$OUT" = "true"; \
	"$$BIN" settings list | grep -q 'cspine.cli=true'; \
	"$$BIN" calc "2+2" | grep -q '^4$$'; \
	"$$BIN" actions app | grep -q 'app.open'; \
	"$$BIN" clipboard ingest "hello-cspine"; \
	"$$BIN" clipboard list | grep -q 'hello-cspine'; \
	CLIP_ID=$$("$$BIN" clipboard list | awk '/hello-cspine/ {print $$1; exit}'); \
	"$$BIN" clipboard pin "$$CLIP_ID" on | grep -q '^ok pinned '; \
	"$$BIN" clipboard list | grep -q "^\\* $$CLIP_ID"; \
	"$$BIN" quicklink add Example https://example.com ex; \
	"$$BIN" quicklink list | grep -q 'Example'; \
	echo "cli-e2e: ok (settings + calc + clipboard pin + quicklink under temp HOME)"

# Ad-hoc release zip (not notarized — Dev ID last in queue).
# Version is read from VERSION; `version-consistency` checks Swift/plist/cask mirrors.
release: app
	@set -euo pipefail; \
	VERSION=$$(tr -d '[:space:]' < VERSION); \
	mkdir -p dist; \
	( cd dist && ditto -c -k --keepParent Summon.app "Summon-$${VERSION}.zip" ); \
	shasum -a 256 "dist/Summon-$${VERSION}.zip"; \
	echo "release: dry-run artifact dist/Summon-$${VERSION}.zip (ad-hoc)"

clean:
	$(SWIFT) package clean
	rm -rf .build
