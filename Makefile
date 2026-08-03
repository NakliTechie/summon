# Summon — Makefile wrappers (handoff §1).
# Gate: `make verify` is the merge definition of done.

SHELL := /bin/bash
SWIFT := swift
BUILD_FLAGS :=
# Removability: SUMMON_AI_ENABLED=0 make build  (omits SummonAI product)
export SUMMON_AI_ENABLED ?= 1

.PHONY: build test verify release clean cli-e2e help

help:
	@echo "Targets: build test verify release clean cli-e2e"

build:
	$(SWIFT) build $(BUILD_FLAGS)

test:
	$(SWIFT) test $(BUILD_FLAGS)

# Partial gate for C-spine; grows per chunk toward full handoff §8.
verify: test cli-e2e
	@echo "verify: unit+integration + journal-replay + cli-e2e + stub-ui (C-spine subset)"
	@echo "verify: latency/network/shim/removability/lint not yet in gate (later chunks)"

# One action end-to-end via the real CLI binary (C-spine).
cli-e2e: build
	@set -euo pipefail; \
	TMP=$$(mktemp -d); \
	export HOME="$$TMP"; \
	BIN="$$($(SWIFT) build $(BUILD_FLAGS) --show-bin-path)/summon-cli"; \
	"$$BIN" version | grep -q 'spine'; \
	"$$BIN" settings set cspine.cli true; \
	OUT=$$("$$BIN" settings get cspine.cli); \
	test "$$OUT" = "true"; \
	"$$BIN" settings list | grep -q 'cspine.cli=true'; \
	echo "cli-e2e: ok (settings set/get/list under temp HOME)"

release:
	@echo "release: not implemented until C5 (sign/notarize/staple/appcast)"
	@exit 1

clean:
	$(SWIFT) package clean
	rm -rf .build
