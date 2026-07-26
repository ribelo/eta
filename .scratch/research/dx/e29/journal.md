# DX-E29 Journal — sealed predictions

Sealed after the frequency census (`census.md`), before any code. This file
is never edited after the seal commit; follow-ups live in separate files.

## Frequency findings (actual, from census.md)

Orchestrator's count to verify was "nested-`par` sites: 2, one test file".

Actual: **3 nested sites, 2 test files** — the orchestrator missed the
right-nested second-argument form at `test/laws/law_properties.ml:463`.
All three are test-harness machinery (promise-interleaving suites, one
qcheck cleanup law); none is consumer-shaped "three fetches" code. Zero
nested sites in `lib/` product code, `examples/`, `drivers/`, or
`http-testsuite/`. 143 compiled flat `par` call expressions at 140 sites;
nesting rate ≈ 2.1%. No pipeline nests, no partial applications, no
`Syntax` spelling, no data-flow nesting, no fan-out above 3.

Straight answer to design question 1: the pain is **not** demonstrated
in-repo. The case is purely structural: E9b made `Effect.par` THE spelling
for concurrent products, so external consumers with 3+ heterogeneous
concurrent fetches are forced into nested tuples or a flattening `map`.
An in-repo census cannot measure that consumer-side pain (Eta is a
library; the corpus above is the runtime authors' own usage).

## Hypothesis ledger (at seal time)

| Candidate | Steelman | Evidence that would falsify | Status |
|---|---|---|---|
| **A — `par3`/`par4` flat tuples** | Semantics inherit from the same `par_run_forks` machinery with nothing hidden (unlike E6's `with_2`/`with_3`, which hid acquisition strategy); flat triple `(a, b, c)` is the honest spelling of an already-explicit concurrency decision; the alternative spelling `Effect.map (fun ((a,b),c) -> (a,b,c)) (Effect.par (Effect.par a b) c)` is pure noise around zero strategy content. | Review reads the pair as arity furniture (the `sync_option` pattern); semantics do not inherit cleanly; a new footgun appears in red-team. | **Selected for build.** |
| **B — builder / applicative chain** | No arity cap; scales past 4. | Census shows max `par` fan-out of 3; the cap-4 rule "beyond 4, use `all` or nested `par`" is never shown to bite. | **Deferred, untested.** No evidence base in-repo; revive only if the review or downstream evidence shows the cap biting. More machinery than the demonstrated shape needs. |
| **C — kill (status quo)** | T4: sugar follows demonstrated frequency; in-repo frequency is ≈ 0; `sync_option` died on exactly this. | Eta is a library for external consumers; in-repo frequency measures only the runtime authors' own usage and cannot refute consumer-side pain. The E6 kill rationale (name hid execution strategy) does not transfer: `par3` hides nothing. | **Alive; delegated to the pre-registered review kill gate.** Not self-executed: the objective places the kill gate in the PR review, and the structural question it settles is the experiment's point. |

## Decision

**Build A** (`par3` + `par4`, one concept, arity cap 4), report the
frequency evidence straight, and submit to the pre-registered review gate.

## Sealed predictions

- **P1 — frequency completeness.** No additional nested-`par` form
  (spacing, pipeline, partial application, Syntax, data-flow) will surface
  beyond the 3 sites in `census.md`.
- **P2 — semantics inheritance.** `par3`/`par4` implemented as flat forks
  over the existing `par_run_forks` machinery will pass order,
  fail-fast-from-each-position, cancel-all-siblings, finalizer-parity, and
  blueprint-aggregation tests with **zero** changes to runtime, switch, or
  cancellation machinery and **zero** changes to `par`/`all`/`map_par`/
  `Syntax`. One known honest difference from literal nesting will be
  documented, not hidden: under simultaneous multi-child failure the cause
  tree is flat (`Cause.Concurrent` of the observed failures, like `all`),
  not `Concurrent`-of-`Concurrent` as literal `par (par a b) c` nesting
  would produce. `par`'s own contract does not pin nesting depth, so this
  is not a contract violation.
- **P3 — census delta.** `effect.mli` concurrent-product vals
  (`par`, `all`, `all_settled`, `map_par`): 4 → 6 (+2 vals, +1 concept,
  +0 modules). Law registry: +4 claim rows (`par3` order, `par3`
  fail-fast/cancel-all, `par4` order, `par4` fail-fast/cancel-all), each
  with a named qcheck property in `test/laws/law_properties.ml`.
- **P4 — footgun delta.** −1 / +0. Removed: the nested-tuple
  pattern-mismatch confusion class for arities 3–4 (`((a, b), c)` vs
  `(a, b, c)`). Honest note, sealed now so the report cannot inflate it:
  OCaml's typechecker already rejects a mismatched pattern, so the win is
  spelling and error clarity, not a new static guarantee. Predicted new
  footguns: none (the "5th effect" case is covered by the documented
  arity-cap rule; failure-position observability is inherited unchanged
  from `par`).
- **P5 — review outcome.** PROMOTE: the review prefers flat tuples over
  nested `par` + flattening `map`. Confidence ≈ 55%. The kill risk is the
  `sync_option` reading — arity furniture against ≈ 0 in-repo frequency.
  The promote case: the comparison is not E6's ladder (whose nesting
  carried visible strategy) but nesting that carries none; and the
  library-outward framing makes in-repo frequency weak evidence.
- **If killed:** excise `par3`/`par4` and their tests completely, no
  rename rescue; nested `par` + flattening `map` remains the documented
  spelling; the report and census stand as the evidence record.
