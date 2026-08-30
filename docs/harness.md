# Summon — The Action Harness

*How Summon turns natural language into actions without letting the model lie about them.*

This document explains one mechanism: the **deterministic action harness** that
sits between an on-device language model and the machine. Its single guarantee:

> **Summon never reports an action it did not actually perform.**

A small on-device model (Apple Foundation Models, ~3B params) is good at
understanding a request and bad at reliably calling a tool and telling the truth
about the result. The classic failure of a "let the model call tools" design is
the model narrating success it never achieved — *"Done, I've emptied your
trash!"* when nothing ran. Summon removes that failure mode by construction: the
model is **never** the thing that acts, and it is **never** the source of the
success claim. Both belong to deterministic code.

The rest of this doc is the design and the invariant it upholds. The tests that
hold it in place live in
[`Tests/SummonAITests/HarnessTruthfulnessTests.swift`](../Tests/SummonAITests/HarnessTruthfulnessTests.swift)
and [`Tests/SummonAITests/MutatingToolsTests.swift`](../Tests/SummonAITests/MutatingToolsTests.swift).

---

## 1. The three shapes of a response

Every AI-routed request resolves to exactly one of three shapes
([`AIResponse.Kind`](../Sources/SummonAI/AILadder.swift)):

| Kind | Meaning | Who produced the text |
|---|---|---|
| `.answer(text)` | Read-only reply. Nothing executed. | The model (for a question) **or** deterministic code (for a decline). |
| `.performed(text)` | A safe, reversible action **the harness already ran**. | Deterministic code — a truthful past-tense summary of the *actual* action. |
| `.staged(proposalID)` | A destructive action, held in amber for one-click Accept. **Nothing ran yet.** | n/a — the action is parked, not performed. |

The load-bearing distinction is between `.performed` and everything else.
`.performed` is the **only** shape that asserts "this happened," and — see §3 — it
is emitted only after the machine confirms it happened.

---

## 2. The pipeline: parse deterministically, never ask the model to act

`SummonAIService.respond(prompt:actor:)`
([`AILadder.swift`](../Sources/SummonAI/AILadder.swift)) routes a request in a
fixed order, before any model is consulted for action:

```
                          user text
                              │
             ┌────────────────▼─────────────────┐
             │ SummonActionParser.parse(text)    │  deterministic NL → typed CoreAction
             └────────────────┬─────────────────┘
                   action?     │   nil
              ┌───────────────┘     └───────────────┐
              ▼                                       ▼
     performOrStage(action)                 declineReason(text)?
              │                              ┌────────┴────────┐
   ┌──────────┴──────────┐          reason  │                 │  nil
   ▼                     ▼                   ▼                 ▼
destructive?         safe?           .answer(honest       ladder.complete(text)
   │                    │             "can't yet")         → .answer(model text)
   ▼                    ▼
 .staged           core.dispatch(action)
 (amber Accept)          │
                         ▼
              switch on ACTUAL outcome  ← §3
```

Two design decisions make the guarantee possible:

1. **The parser owns the action decision, not the model.**
   [`SummonActionParser`](../Sources/SummonAI/SummonActionParser.swift) maps
   natural language to a typed [`CoreAction`](../Sources/SummonCore/CoreAction.swift)
   with plain string matching and field extraction. Intent classification
   ([`SystemReaders.mutatingIntents`](../Sources/SummonAI/MutatingTools.swift))
   has two guardrails baked in — an *information-question strip* (so "how do I
   make a snippet" teaches instead of acting) and an *invite gate* (an action
   needs an explicit verb/object, or for volume an explicit target level). If the
   text doesn't parse to a concrete action, the parser returns `nil` and the
   request falls through to the answer/search path. **The model is never handed a
   tool to call for a mutating action**, so it can never fail to call one, and
   can never claim it did.

2. **A clearly-unsupported command gets a deterministic honest decline.**
   `SummonActionParser.declineReason` recognizes commands Summon *can't* do yet
   (email, reminders, calendar, file moves, …) and returns a flat "Summon can't
   do X yet." The model is not asked, so it can't improvise a helpful-sounding
   *"Sure, I'll remind you…"* for a capability that does not exist.

---

## 3. Do-safe / stage-destructive — and report the *real* outcome

`performOrStage` is where truthful reporting is enforced. It is a pure mapping
from the **actual** result of dispatch to the reported shape.

**Destructive actions are staged, never run.** Whether an action is destructive
is decided by [`DestructiveGuard.isDestructive`](../Sources/SummonCore/DestructiveGuard.swift),
not by the model. Empty-trash, sleep, lock, delete, and any `summon://system/*`
effect that isn't on the reversible allow-list (set-volume, sleep-display,
dark-mode) are destructive. A destructive action is written to the staged-proposal
store and returned as `.staged` — the effect **never reaches the machine** until
the user clicks Accept. So a natural-language "empty the trash" cannot empty the
trash, and — crucially — the response is `.staged`, never `.performed`.

**Safe actions run through the single action bus, and the report mirrors the bus.**
A reversible action is dispatched to [`ActionBus`](../Sources/SummonCore/ActionBus.swift)
— the one write path in the system (invariant 7) — which returns a typed
[`ActionResult.Outcome`](../Sources/SummonCore/ActionEnvelope.swift). The harness
switches on that outcome:

| Actual bus outcome | Reported shape | Claim made |
|---|---|---|
| `.applied` | `.performed(summary)` | "This happened." — and it did. |
| `.rejected(reason)` | `.answer("Couldn't do that: \(reason)")` | An honest failure. No success asserted. |
| `.staged(id)` | `.staged(id)` | Parked for Accept. |

The success text for `.performed` comes from
`SummonAIService.performedSummary(_:)` — a deterministic past-tense summary
derived from the **typed action that was applied** ("Snippet "sig" saved.",
"Volume set to 30%."). It is not the model's output. The model's completion never
appears in a `.performed` or `.staged` response at all.

This is the whole guarantee in one sentence: **the reported shape is a function
of the machine's actual outcome, never of the model's narration.**

---

## 4. The audit trail makes it checkable after the fact

Every dispatch — applied, rejected, or staged — is appended to the
[`ActionJournal`](../Sources/SummonCore/ActionJournal.swift), an append-only log
that records the typed action, the outcome, and the actor (`actor=user`,
`actor=agent`, `actor=ext`). The journal is the persistent, independently
inspectable record that "reported" and "actually happened" agree: a `.performed`
response has a corresponding `applied` journal row; a staged destructive action
has a `staged:` row and **no** `applied` effect row for the destructive effect.
The tests assert exactly this correspondence.

---

## 5. What the tests pin down

[`HarnessTruthfulnessTests`](../Tests/SummonAITests/HarnessTruthfulnessTests.swift)
covers the guarantee end-to-end, machine-safely (store actions and the staging
path only — no test ever runs a real system effect):

- **Execution is real.** A safe action dispatched through `respond` actually
  mutates the store, and the journal records it `applied`.
- **The report matches reality.** `.performed` is emitted *only* on an `applied`
  outcome; its text is the harness-derived summary and never contains the model's
  (booby-trapped) output.
- **Destructive actions never run and are never claimed.** "empty the trash"
  returns `.staged`, records a staged proposal, drives **zero** executor effects,
  and writes no `applied` effect row — the machine is untouched.
- **No over-claim when the harness can't perform.** When the action can't be
  carried out, the harness returns an honest non-claim, never a fabricated
  "done."
- **The model is never the actor.** A model rigged to output *"I did it"* never
  has that text surface in a performed, staged, or declined response.
- **Failure is honest.** A rejected dispatch is reported as a failure and
  recorded `rejected:` in the journal — never as success.

Run them:

```bash
swift test --filter HarnessTruthfulnessTests
```

---

## 6. Scope and honest limits

- The harness guarantees truthful *reporting* of what the deterministic layer
  did. It does not claim the on-device model's *answers* to questions are
  correct — a `.answer` is the model's text, shown read-only, and is out of
  scope for this guarantee.
- The reversible/destructive split is a fixed policy in `DestructiveGuard`, not a
  model judgment. Adding a new action means classifying it there explicitly; the
  default for anything under `summon://system/*` is destructive (stage it).
- Model tool-use (letting the model *name* a read-only reader like battery or
  datetime) exists for grounding answers only — those readers are zero-egress and
  cannot mutate anything ([`SummonToolbox`](../Sources/SummonAI/SummonToolbox.swift)).
  No mutating capability is ever placed behind a model tool call.
