# Summon — Makefile wrappers (handoff §1).
# Gate: `make verify` is the merge definition of done.

SHELL := /bin/bash
SWIFT := swift
BUILD_FLAGS :=
# Removability: SUMMON_AI_ENABLED=0 make build  (omits SummonAI product)
export SUMMON_AI_ENABLED ?= 1

.PHONY: build test verify release clean cli-e2e lint removability app cask-local help

help:
	@echo "Targets: build test verify app cask-local release clean cli-e2e lint removability"

# Ad-hoc Summon.app under dist/ (no Developer ID).
app:
	bash packaging/macos/build-app.sh

# Local Homebrew cask dry-run against ad-hoc app zip (handoff READY-cask).
cask-local: app
	bash packaging/homebrew/test-local-cask.sh

build:
	$(SWIFT) build $(BUILD_FLAGS)

test:
	$(SWIFT) test $(BUILD_FLAGS)

lint:
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint --strict --config .swiftlint.yml; \
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

# C-spine + C0 shim fixtures + lint + removability. Latency/network grow later.
verify: test cli-e2e lint removability
	@echo "verify: unit+integration + journal-replay + cli-e2e + stub-ui + shim fixtures + lint + removability"
	@echo "verify: latency/network/i18n not yet in gate (later chunks)"

# One action end-to-end via the real CLI binary (C-spine).
cli-e2e: build
	@set -euo pipefail; \
	TMP=$$(mktemp -d); \
	export HOME="$$TMP"; \
	BIN="$$($(SWIFT) build $(BUILD_FLAGS) --show-bin-path)/summon-cli"; \
	"$$BIN" version | grep -E -q 'spine|c1|m1'; \
	"$$BIN" settings set cspine.cli true; \
	OUT=$$("$$BIN" settings get cspine.cli); \
	test "$$OUT" = "true"; \
	"$$BIN" settings list | grep -q 'cspine.cli=true'; \
	"$$BIN" calc "2+2" | grep -q '^4$$'; \
	"$$BIN" actions app | grep -q 'app.open'; \
	"$$BIN" clipboard ingest "hello-cspine"; \
	"$$BIN" clipboard list | grep -q 'hello-cspine'; \
	"$$BIN" quicklink add Example https://example.com ex; \
	"$$BIN" quicklink list | grep -q 'Example'; \
	echo "cli-e2e: ok (settings + calc + clipboard + quicklink under temp HOME)"

release:
	@echo "release: not implemented until C5 (sign/notarize/staple/appcast)"
	@exit 1

clean:
	$(SWIFT) package clean
	rm -rf .build
