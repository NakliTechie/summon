# AGENTS.md — Summon

Summon is designed to be driven by machines, not just humans. This file is for coding agents working *on* the repo. For the runtime agent face (the `summon` CLI + socket that agents drive to *use* Summon), see the vision doc §5.

## Start here

Read the spec bundle in [`/docs`](docs/) before any change — see [`CLAUDE.md`](CLAUDE.md) for the map and the non-negotiable operating rules. The [`docs/summon-ux-reference-006.html`](docs/summon-ux-reference-006.html) is the drawn product; build against it.

## The gate — what "done" means

`make verify` is the merge gate and the only definition of done. It runs, machine-checkable and human-free (handoff §8):

1. Unit + integration green across targets.
2. **Replay** — action journal replayed into a fresh core reconstructs store state byte-equal.
3. **Latency** — invoke-to-visible < 50 ms, keystroke-to-results < 16 ms, p95 over 100 runs (arm64 CI).
4. **Removability** — full suite minus `SummonAI` (build flag): everything green with the AI target absent.
5. **Sovereignty/network** — instrumented walkthrough asserts the only egress is the appcast fetch (plus user-invoked AI calls, each matched to a journal record).
6. **Shim fixtures** — unmodified store extensions execute headlessly; sandbox-escape fixtures fail loud.
7. Lint (SwiftLint strict) + token contrast test + i18n completeness.

## Working rhythm

- `/forward-pass` in fresh context after every chunk; the fix-list closes before the next chunk opens.
- No-progress exit: same failure 3× consecutive → write the tried-trail to [`NAKLITECHIE-PROJECT-STATE.md`](NAKLITECHIE-PROJECT-STATE.md) and escalate.
- Park walls (external deps — signing creds, Apple Foundation Models on CI, Homebrew cask): build against a stand-in behind a seam, swap real on arrival, re-verify.
- All reports in ATTEST-100 blocks; evidence marks on every claim.

## Actor model at runtime

Five actors, each with a trust boundary (vision doc §2): User · Agent (machine, opt-in, default OFF, propose-only for destructive ops) · System · Extension code (untrusted 3rd-party JS — outside by default) · AI provider (outside; data leaves only on explicit action, to the user's own provider). Every action carries an `actor=` tag into the local journal.
