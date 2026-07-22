# DX-E22 report — executable mli laws

## Recommendation

**PROMOTE the scoped policy and mli-anchored suite.** Five modules are declared
inventory-complete: 99 stated claims have direct qcheck coverage and 101 external
registry rows point to existing named executable suites. Twenty-three exact
historical gap clusters are dated and owned rather than omitted. Two schedule
model claims remain visibly prose-pending. Sixty-three deterministic qcheck
properties cover the direct class; qcheck remains test-only. The rule is
prospective across every `.mli`: new or changed law-bearing prose must add its
test and registry row in the same change, with no new-debt escape hatch.

## Observation equivalence

Algebraic laws compare fresh `Eta_test.Run.run` outcomes made with the same
explicit seed. Equality is diagnostically normalized `Exit.t` plus the complete
ordered `Run.event` stream. Duplicate category projections (`logs`, `spans`,
`metrics`, `sleeps`) are removed from normalized equality only after both
outcomes prove `pending_fibers = Some []`; the algebraic class has no legitimate
background work.

The algebraic generated class is finite depth-three immutable blueprints from
four base leaves (`Pure`, `Fail`, `Log`, `Yield`) and six recursive forms (`Map`,
`Bind`, `Bind_error`, `Fold`, `Finally`, `Delay`), plus total printable
enumerated continuations. It contains no defect or owned-cancellation leaf;
separate lifecycle matrices cover success, typed failure, defect, and
cancellation. Concurrency/primitive traces and schedule parameters are bounded.
Arbitrary `sync`, external I/O, shared mutation, unbounded programs, and
scheduler deadlines are excluded.

## Inventory coverage

`review/LAWS.md` is the authoritative one-claim-per-row registry: exact
normative span → exact qcheck property or verified external named test →
provenance class. Summary:

| Mli | Direct qcheck claims | Registered external rows | Model claims |
| --- | ---: | ---: | ---: |
| `effect.mli` | 48 | 84 | 0 |
| `schedule.mli` | 6 | 3 | 2 |
| `channel.mli` | 12 | 0 | 0 |
| `queue.mli` | 16 | 14 | 0 |
| `semaphore.mli` | 17 | 0 | 0 |
| **Total covered rows** | **99** | **101** | **2** |

The seven algebraic/error equations were promoted into short normative
`effect.mli` prose. The two schedule bootstrap laws remain executable but are
explicitly model/prose-pending because their valid public domains need separate
review. All 63 properties pass 50 deterministic generated inputs each.

## Refinements and counterexamples

No prior production mli wording proved false. `effect.mli` was edited only to
state the previously prose-pending monad/error-channel equations that E22 already
tested.

- Fail-fast/loser cancellation is asserted after the combinator completes and
  cancellation-protected cleanup has emitted exactly once; no scheduler
  deadline or “no later event” claim is made.
- Successful finalizers emit explicit log events; the suite does not invent a
  finalizer seam that `Eta_test.Run` says it lacks.
- Monad laws range over total enumerated functions, not arbitrary effectful OCaml
  functions.
- Delay monotonicity covers valid exponential, fibonacci, and nonnegative linear
  inputs, not jitter or arbitrary delay modifiers.
- Scope LIFO found and shrank a fixture-construction bug to `[0; -1]`; correcting
  acquisition construction with `List.fold_right` made the property test the law.
- Upstream OCaml 5.4 rejected `effect` as a local binding keyword; renaming it
  `program` fixed test portability without changing a law.

The schedule rows remain bootstrap model laws requested by E22 because current
constructor declarations do not state those semantics. FG-E22-001 is dated
model-prose debt with an owner and deadline. FG-E22-002 through FG-E22-005 are
closed by direct properties for
`all`/`all_settled`, scope exits/nesting, Channel sender cancellation, and
Semaphore bracket/abort semantics. FG-E22-006 is closed by exact named-suite
registrations. Retrospective migration outside the five declared modules is
partitioned into dated, owned D-E22-001 through D-E22-005 rather than an
open-ended “next tranche.”

## Red team and review

`redteam/vacuous-property.md` records a deliberately implementation-independent
self-comparison and rejects it. Qcheck cannot generically prove non-vacuity;
separate construction of both sides, required exit matrices/cancellation
observations, readable inventory, and maintainer review are the controls.

The two least-trusted production laws—`par` fail-fast cancellation and
Semaphore blocked-waiter cancellation—passed 50 adversarial inputs each. No real
production violation was found. The test-construction counterexample above is
recorded separately from production evidence.

Independent review initially returned HOLD and identified weak lifecycle exit/
ordering assertions, representative-only override evidence, narrow primitive
traces, schedule-source overstatement, and one vacuity-document overclaim. The
suite and review packet were corrected rather than waiving those findings.
Lifecycle now preserves/observes exits and order; clock, random, logger, and
tracer are matrixed; Channel waiters, all Queue modes, and every valid generated
Semaphore request are exercised. Independent re-review returned **READY** with
no remaining must-fix finding.

Follow-up review then found six policy-integrity failures. The direct truncated-
schedule vacuity is documented in `redteam/vacuous-property.md`; exact schedule
length, exact outer-clock values, empty algebraic census, and both observable
completion directions are now hard assertions. The census was rebuilt from
normative spans and expanded through concurrency, cleanup, primitive, nested
override, interceptor, and schedule-driver claims rather than relabeling the
old 22 rows.

Strict re-review held once more on combined `bind_error` claims, Queue shutdown
idempotence, and bracket cleanup-failure composition. Separate direct properties
and one-claim rows closed all three; final independent verdict: **READY**.

Follow-up 2 scopes the promise honestly. The repository no longer claims that
all historical `.mli` prose already has qcheck coverage. The five named census
modules have a complete map through direct qcheck rows, exact registrations of
existing runtime/backend tests, or explicit dated historical gaps; outside them,
the same-change rule has teeth for all future edits and bounded retrospective
work is dated and owned.

The three requested anti-vacuity fixes are direct: `race` uses two finite tagged
producers in both completion directions; `par` uses two ranked failures plus a
pending cleanup sibling in both failure directions; and `Drop` generates nesting
depth, interceptor position, record body, and attribute shapes, then predicts
the exact executed prefix, skipped suffix, and absent sink. The Drop review
finding demonstrates that the fixed-example prohibition rejects nominal
50-case repetition.

Strict follow-up-2 review repeatedly held on omitted claims and overbroad test
pointers. The final map distinguishes 200 covered rows from 23 exact dated claim
clusters and gives every external row a named executable source. Final
independent verdict: **READY**.

## Dependency boundary

`qcheck` appears only in `test/laws/dune` and Nix development/test provisioning.
It does not appear in `dune-project`, any generated `*.opam`, or any installable
library stanza. The pre-wiring `ocamlfind` check had no qcheck match; the wired
OxCaml and mainline shells expose qcheck 0.91.

## Gates

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS (63 properties / 3,150 generated qcheck inputs) |
| `nix develop -c eta-oxcaml-test-shipped` | PASS (explicitly includes `test/laws`) |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws --force` | PASS, native OCaml 5.4 |

The suite is runtime-backed by `eta_test`/`eta_eio`/`Eio_main`, so it is not a
js_of_ocaml-portable suite. A JS run would require a distinct `eta_jsoo`
observation engine; qcheck portability alone is insufficient.
