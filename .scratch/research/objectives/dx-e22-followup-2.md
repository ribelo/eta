# Follow-up 2: DX-E22 — scope the policy honestly + three property fixes

Round-two review: 5 of 6 original findings CLOSED (verified). Remaining
work is one policy-integrity item and three property strengthenings. The
principle: **the policy must never claim what the repository doesn't do
today** — and the census must be a map a reader can trust, not a subset
that quietly omits.

## 1. Scope the policy honestly (resolves finding 1 + fresh finding 1)

The oracle is right that "Every law stated in an `.mli` must have a named
qcheck property" + admitted uncensused prose (FG-E22-006) is an
inconsistent promote. Total qcheck coverage of every mli claim is the
ongoing policy's work, not this bootstrap's. Amend AGENTS.md and LAWS.md
to the scoped, enforceable version:

- **Census modules** (`effect.mli`, `schedule.mli`, `channel.mli`,
  `queue.mli`, `semaphore.mli`): every law-bearing claim must have a
  qcheck property in `test/laws/` — no exceptions, no debt.
- **Registered external coverage**: a law-bearing claim covered by a
  NAMED executable test elsewhere (e.g. `Effect.async`'s six guarantees,
  which have the E13 shared suite) is registered in LAWS.md with the
  claim, the span, and the test pointer — not duplicated, not omitted.
  Verify each registration actually names real tests; any cluster with no
  named test anywhere gets properties now or becomes explicitly-listed
  dated debt (owner + follow-up), not an open-ended FG.
- **Prospective rule (the policy's teeth)**: any NEW or CHANGED
  law-bearing prose in any `.mli` requires its test (property or
  registered suite) in the same change.

In particular, register or cover: `Effect.async` cardinality/cancellation
rules, conditional/error combinators, `on_exit`/`on_error`/`on_interrupt`,
background lifecycle, Queue admission policies. LAWS.md's final state must
let a reader answer "does this claim have a test?" for every one.

## 2. `Drop` property is a fixed example (fresh finding 2)

`law_properties.ml` (~2129–2153): `_tag` is unused — all 50 cases run the
identical program, violating the policy's own fixed-example clause.
Generate real variance: interceptor positions, nesting depths, whether
`Drop` is outer/middle/inner, record/attribute shapes — and derive the
expected skipped suffix and sink result from the input.

## 3. `race` first-value discrimination (fresh finding 3)

M09: the loser is `never`, so only one branch can produce a value — an
implementation biased toward the second position still passes. Add two
finite, distinctly tagged competitors; force both completion directions;
assert the winner is the actual first producer (the held-resource
cancellation case stays for M10).

## 4. `par` first-failure discrimination (fresh finding 4)

M10's sibling never fails — the property proves propagation of the sole
failure, not of the FIRST observed failure. Use two ranked failures plus a
pending cleanup sibling (the pattern the strengthened `all` property
already uses).

## Records

Journal: append-only entry on the policy-scoping decision (record WHY:
bootstrap deliverable vs. ongoing policy; the oracle's two offered
resolutions; the choice and its rationale). LAWS.md final form. Red-team:
note the Drop self-catch as evidence the policy's anti-vacuity clause
bites. Re-triage FG items: closed/registered/dated-debt only — nothing
open-ended.

## Gates

Full re-run (native trio; mainline `test/laws` + `@install`).

## Done means

`E22 READY FOR REVIEW` / `E22 BLOCKED: <reason>` / `E22 STOP: <§4.6>`.
Same scope fence. This file stays uncommitted.
