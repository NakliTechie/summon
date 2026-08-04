# AGENTS.md — Summon

Summon is designed to be driven by machines, not just humans. This file is for coding agents working *on* the repo. For the runtime agent face (the `summon` CLI + socket that agents drive to *use* Summon), see the vision doc §5.

## Start here

Read the spec bundle in [`/docs`](docs/) before any change — see [`CLAUDE.md`](CLAUDE.md) for the map and the non-negotiable operating rules. The [`docs/summon-ux-reference-006.html`](docs/summon-ux-reference-006.html) is the drawn product; build against it.

## The gate — what "done" means

`make verify` is the merge gate and the only definition of done for a merge.

### Current verify recipe (what actually runs)

Machine-checkable, human-free:

1. **Unit + integration** — `swift test` (includes journal-replay, shim fixtures, token contrast).
2. **CLI e2e** — settings / calc / clipboard / quicklink under temp `HOME`.
3. **Lint** — SwiftLint strict.
4. **Removability** — `SUMMON_AI_ENABLED=0` package dump + build + test (AI product absent).
5. **Walkthrough** — CLI role walk (`scripts/walkthrough.sh`); not a browser / full AppKit soak.
6. **Latency-soft** — `summon latency` probe (prints p95 vs budget; **does not fail the gate**).

### Deferred (vision / handoff still list; not yet hard-gated)

- Hard **latency** fail (p95 < 50 ms invoke / < 16 ms keystroke on arm64 CI).
- **Network sovereignty** instrumented egress assert (only appcast + journaled user AI/web).
- **i18n completeness** as a separate gate line (L10n keys exist; full locale set not gated).
- Unmodified **third-party store** packages (fixtures are synthetic).

## Working rhythm

- `/forward-pass` in fresh context after every chunk; the fix-list closes before the next chunk opens.
- No-progress exit: same failure 3× consecutive → write the tried-trail to [`NAKLITECHIE-PROJECT-STATE.md`](NAKLITECHIE-PROJECT-STATE.md) and escalate.
- Park walls (external deps — signing creds, Apple Foundation Models on CI, Homebrew cask): build against a stand-in behind a seam, swap real on arrival, re-verify.
- All reports in ATTEST-100 blocks; evidence marks on every claim.

## Actor model at runtime

Five actors, each with a trust boundary (vision doc §2): User · Agent (machine, opt-in, default OFF, propose-only for destructive ops) · System · Extension code (untrusted 3rd-party JS — outside by default) · AI provider (outside; data leaves only on explicit action, to the user's own provider). Every action carries an `actor=` tag into the local journal.
