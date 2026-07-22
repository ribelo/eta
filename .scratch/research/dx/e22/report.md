# DX-E22 report — executable mli laws

## Recommendation

**PROMOTE the policy and initial 22-law suite.** The bootstrap inventory is
covered by deterministic qcheck properties on both supported native compilers,
qcheck remains test-only, and the repository gates pass. Five review-discovered
inventory/documentation gaps are tracked as follow-up footguns rather than
hidden by the bootstrap count.

## Observation equivalence

Algebraic laws compare fresh `Eta_test.Run.run` outcomes made with the same
explicit seed. Equality is diagnostically normalized `Exit.t` plus the complete
ordered `Run.event` stream. Duplicate category projections (`logs`, `spans`,
`metrics`, `sleeps`) and the fiber-census field are removed from general
equality; cancellation laws instead require the census to be available and
empty as a side-condition.

The generated class is finite depth-three immutable blueprints from five base
leaves and five recursive forms, total printable enumerated continuations,
bounded concurrency/primitive traces, valid schedule parameters, and explicit
owned cancellation of any `never`. Arbitrary `sync`, external I/O, shared
mutation, unbounded programs, and scheduler deadlines are excluded.

## Inventory coverage

| # | Law | Qcheck property | Status |
| ---: | --- | --- | --- |
| 1 | map identity | `map identity` | PASS |
| 2 | map composition | `map composition` | PASS |
| 3 | bind associativity | `bind associativity` | PASS |
| 4 | bind left identity | `pure/bind left identity` | PASS |
| 5 | bind right identity | `pure/bind right identity` | PASS |
| 6 | bind_error left identity | `bind_error left identity` | PASS |
| 7 | fold coherence | `fold coherence with map/bind_error` | PASS |
| 8 | par pair order | `par pair input order` | PASS |
| 9 | par fail-fast | `par fail-fast cancels pending sibling and waits for observable finalizer` | PASS |
| 10 | map_par order | `map_par input order across interleavings` | PASS |
| 11 | race loser cancellation | `race pending-loser cancellation` | PASS |
| 12 | finally exactly once/all exits | `finally exactly once across success/typed-failure/defect/cancellation exit kinds` | PASS |
| 13 | scope LIFO | `scope reverse acquisition/release order` | PASS |
| 14 | with_resource release/all exits | `with_resource release across success/typed-failure/defect/cancellation exit kinds` | PASS |
| 15 | Channel close fence | `Channel graceful close fence/drain/reason ordering` | PASS |
| 16 | Semaphore cancellation safety | `Semaphore waiting-cancellation safety/no permit consumption` | PASS |
| 17 | Queue close/error ordering | `Queue graceful close/error ordering` | PASS |
| 18 | schedule monotone delays | `monotone delay sequences for valid exponential/fibonacci/linear schedules` | PASS |
| 19 | recurs step count | `recurs n step count` | PASS |
| 20 | override restoration/all exits | `dynamic override restoration across each exit kind` | PASS |
| 21 | override sibling isolation | `override sibling isolation under par` | PASS |
| 22 | log pipeline order | `log pipeline order filter -> attrs -> transform -> sink` | PASS |

`review/LAWS.md` is the tracked one-line-per-law source/census document. Actual
split: Effect 17, Schedule 2, Channel 1, Queue 1, Semaphore 1; total 22.

## Refinements and counterexamples

No production mli wording proved false, so no mli was edited.

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

The schedule rows are bootstrap model laws requested by E22, but current
`schedule.mli` declarations do not state their semantics in prose. This and four
existing prose clusters omitted by the initial 22 are tracked as FG-E22-001
through FG-E22-005 in `review/LAWS.md`. The sealed +0 footgun prediction was
therefore wrong: actual tracked follow-up delta is **+5**.

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

## Dependency boundary

`qcheck` appears only in `test/laws/dune` and Nix development/test provisioning.
It does not appear in `dune-project`, any generated `*.opam`, or any installable
library stanza. The pre-wiring `ocamlfind` check had no qcheck match; the wired
OxCaml and mainline shells expose qcheck 0.91.

## Gates

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS (includes 22 laws / 1,100 qcheck inputs) |
| `nix develop -c eta-oxcaml-test-shipped` | PASS (explicitly includes `test/laws`) |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws --force` | PASS, native OCaml 5.4 |

The suite is runtime-backed by `eta_test`/`eta_eio`/`Eio_main`, so it is not a
js_of_ocaml-portable suite. A JS run would require a distinct `eta_jsoo`
observation engine; qcheck portability alone is insufficient.
