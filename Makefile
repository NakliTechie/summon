# Summon — Makefile wrappers (handoff §1).
# Gate: `make verify` is the merge definition of done.

SHELL := /bin/bash
SWIFT := swift
BUILD_FLAGS :=

.PHONY: build test verify release clean cli-e2e lint no-model-launcher extension-omission app cask-local distribution-local l1-probe battery walkthrough latency-soft latency-hard network-sovereignty version-consistency help

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

# Deterministic-surface battery: 1000+ generated queries through the headless
# launcher surface, asserting no-throw / correct-kind / no-sensitive-bleed at scale.
# Gated out of `verify` (heavy); run on demand.
battery:
	SUMMON_RUN_BATTERY=1 $(SWIFT) test $(BUILD_FLAGS) \
		--filter RoutingBattery1000Tests \
		--filter DeterministicSurfaceBatteryTests \
		--filter MacawParityBatteryTests

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

# AI is core and always linked. These focused tests assert that launcher and
# search surfaces degrade without an available model instead of dead-ending.
no-model-launcher:
	$(SWIFT) test $(BUILD_FLAGS) --filter LauncherAIIntegrationTests.testUnavailableAIUsesDesignedDegradedCopy
	$(SWIFT) test $(BUILD_FLAGS) --filter WebSearchFlowBatteryTests.testHitsWithoutModelReturnResults
	@PACKAGE_JSON=$$(mktemp /tmp/summon-package.XXXXXX); \
		$(SWIFT) package dump-package >"$$PACKAGE_JSON"; \
		python3 -c "import json,sys; d=json.load(open(sys.argv[1])); t={x['name']:x for x in d['targets']}; assert 'SummonAI' in str(t['summon-cli']['dependencies']); assert 'SummonAI' in str(t['summon-app']['dependencies'])" "$$PACKAGE_JSON"; \
		echo "no-model-launcher: degraded launcher and fetched-link fallback exercised; SummonAI remains core"

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
verify: test cli-e2e lint no-model-launcher extension-omission walkthrough network-sovereignty version-consistency latency-hard
	@echo "verify: unit+integration + journal-replay + cli-e2e + shim + lint + no-model-launcher + extension-omission + walkthrough + network-sovereignty + version-consistency + latency-hard"

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

# One action end-to-end via the real CLI binary (C-spine). Also carries the
# harden 2026-09-10 checks: the recorded SearXNG URL round-trips under $HOME on
# both sides (scripts and CLI), web verbs reject unknown flags / extra tokens,
# and the lifecycle verbs are driven through scripts/fake-docker. SUMMON_TOOL_DIRS
# is exported for the whole recipe so no line can reach the developer's real
# container runtime — a forged recorded URL plus `web remove` once deleted a live
# backend from inside this target.
cli-e2e: build
	@set -euo pipefail; \
	TMP=$$(mktemp -d); \
	export HOME="$$TMP"; \
	export SUMMON_CONTAINER_DIR="$$TMP/container"; \
	export SUMMON_TOOL_DIRS="$$(pwd)/scripts/fake-docker"; \
	export FAKE_DOCKER_SCENARIO=missing; \
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
	mkdir -p "$$HOME/.config/summon"; \
	printf 'http://127.0.0.1:8123/\n' > "$$HOME/.config/summon/searxng.url"; \
	"$$BIN" web status | grep -q 'recordedURL=http://127.0.0.1:8123/'; \
	"$$BIN" web remove | grep -q '^ok web backend removed'; \
	test ! -f "$$HOME/.config/summon/searxng.url"; \
	"$$BIN" web enable >/dev/null; \
	if "$$BIN" web remove --bogus-flag >/dev/null 2>&1; then echo "cli-e2e: web remove accepted an unknown flag"; exit 1; fi; \
	test "$$("$$BIN" settings get web.search.enabled)" = "true"; \
	if "$$BIN" web enable extra >/dev/null 2>&1; then echo "cli-e2e: web enable accepted extra tokens"; exit 1; fi; \
	if "$$BIN" web status --json >/dev/null 2>&1; then echo "cli-e2e: web status accepted an unknown flag"; exit 1; fi; \
	if bash packaging/searxng/searxng-down.sh --help | grep -q 'set -euo pipefail'; then echo "cli-e2e: searxng-down.sh --help leaks shell directives"; exit 1; fi; \
	bash packaging/searxng/searxng-down.sh --help | grep -q 'Remove local backend'; \
	FAKE="$$(pwd)/scripts/fake-docker"; \
	printf 'http://127.0.0.1:8123/\n' > "$$HOME/.config/summon/searxng.url"; \
	if SUMMON_TOOL_DIRS="$$FAKE" FAKE_DOCKER_SCENARIO=exited "$$BIN" web enable >/dev/null 2>&1; then echo "cli-e2e: web enable exited 0 with an unstartable backend"; exit 1; fi; \
	test "$$("$$BIN" settings get web.search.enabled)" = "true"; \
	SUMMON_TOOL_DIRS="$$FAKE" FAKE_DOCKER_SCENARIO=paused "$$BIN" web status | grep -q 'backend=paused (docker)'; \
	SUMMON_TOOL_DIRS="$$FAKE" FAKE_DOCKER_SCENARIO=running "$$BIN" web status | grep -q 'owned=yes'; \
	rm -f "$$HOME/.config/summon/searxng.url"; \
	SUMMON_TOOL_DIRS="$$FAKE" FAKE_DOCKER_SCENARIO=running "$$BIN" web status | grep -q 'owned=no'; \
	OUT=$$(SUMMON_TOOL_DIRS="$$FAKE" FAKE_DOCKER_SCENARIO=running "$$BIN" web remove 2>&1 || true); \
	printf '%s' "$$OUT" | grep -q 'not set up from this profile'; \
	printf 'http://127.0.0.1:1/\n' > "$$HOME/.config/summon/searxng.url"; \
	"$$BIN" settings set web.search.baseURL "" >/dev/null; \
	OUT=$$("$$BIN" web search hello 2>&1 || true); \
	if printf '%s' "$$OUT" | grep -q 'requires a valid provider URL'; then echo "cli-e2e: web search ignores the recorded URL"; exit 1; fi; \
	rm -f "$$HOME/.config/summon/searxng.url"; \
	echo "cli-e2e: ok (settings + calc + clipboard pin + quicklink + web lifecycle under temp HOME)"

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
