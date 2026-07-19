# DX-E6 Sealed Predictions

Sealed before API, documentation, implementation, test, red-team, or review
artifact changes. This file is the prediction record and must not be edited.

## Question and proof obligations

The experiment asks whether `Effect.Scoped.with_2` and `with_3` are an honest,
more readable spelling for concurrently bootstrapping independent scoped
resources than a nested `let@` ladder, while preserving the existing scope and
parallel-combinator semantics. The decisive runtime obligations are
partial-acquire cleanup, reverse registration-order cleanup across every body
exit, interruption during acquisition, and parity with nested brackets.

## Predicted teach-back

Question: second acquire fails — what happens?

Prediction: `with_2` fails with the second acquire's cause and leaves its local
scope. If the first acquire has completed and registered its release, that
release runs exactly once while the scope closes. Fail-fast cancellation stops
an acquire still in progress; an acquire that never completed registered no
release. A release failure remains a finalizer diagnostic and does not enter the
helper's typed result error row.

## Predicted census and footgun deltas

- Lifecycle cluster: 6 vals to 8 vals, with one added concept (`Scoped` helpers).
- Footguns: -1 / +0. The removed footgun is the visually natural nested
  `with_resource` ladder silently serializing independent acquisition; no new
  footgun is expected because lifecycle and fail-fast behavior are inherited
  from existing primitives.
- Justification: replaces the `and@` operator (syntax machinery) with
  composition.

## Likeliest reviewer misreadings

1. The left-to-right labels will be read as sequential acquisition even though
   the implementation uses `par` and starts acquisitions concurrently.
2. “Reverse-order release” will be read as reverse argument order. With
   concurrent acquisition it is reverse successful registration/completion
   order, because the existing scope owns the finalizer stack.

## Prior on the kill gate

I predict `with_3` will rate **better** than the nested ladder, with moderate
confidence (about 65%). Its labels are repetitive, but the flat call makes three
peer resources and concurrent intent visible without three levels of CPS
nesting. The strongest counterprediction is that twelve acquire/release labels
around a three-argument callback will scan as more boilerplate than the ladder;
if reviewers rate that worse, the helpers should be killed and only the recipe
kept, exactly as pre-registered.

## Follow-up 1 — kill decision

The pre-registered kill gate fired after three blinded independent cohort
passes:

| Pass | Ladder rating | `with_3` rating | Preference |
|---|---:|---:|---|
| 1 | 5 | 3 | ladder |
| 2 | 5 | 3 | ladder |
| 3 | 4 | 3 | `with_3` for scanning, despite the lower rating |
| **Median** | **5** | **3** | ladder in 2 of 3 |

The 65%-better prior was a **miss**. The counterprediction that twelve labelled
arguments would scan as worse boilerplate than the ladder was a **hit**. The
consistent diagnosis was that `with_3` carried cardinality but hid acquisition
strategy and release order, while the ladder made its serial lifecycle
structural.

Decision: kill `Effect.Scoped.with_2` and `with_3`; retain the documented
parallel-acquire recipe and port its partial-failure, release-order, and ladder
parity evidence into regression tests. `and@` remains killed by the independent
red-team result. The journal, report, red-team probes, review packet, and
inferred-signature evidence remain as branch provenance.

General finding: *helper names must carry execution strategy, not just
cardinality*. A strategy-carrying name is a separate backlog experiment, not a
rename rescue for E6.
