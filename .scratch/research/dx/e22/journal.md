# DX-E22 Journal — law-property policy

Branch: `research/dx-e22-law-properties`

## Predictions (sealed)

This section is sealed before E22 dependency, test, policy, census, review, or
report changes. Wrong predictions remain as evidence; later entries must not
edit this section.

### Decision and proof obligations

Decision: whether Eta can maintain the policy **“every law in an mli has a
qcheck test”** without overstating observational equivalence, generated program
coverage, or cancellation behavior.

| # | Proof question | Evidence needed | Risk | Predicted result |
| --- | --- | --- | --- | --- |
| E22-P1 | Do the algebraic laws hold for the documented, deterministic blueprint class? | Recursive generated blueprints, deterministic replay, printed counterexamples | Medium | Proven |
| E22-P2 | Do fail-fast and loser-cancellation laws hold without claiming an impossible scheduler deadline? | Adversarial sibling/loser programs with observable protected finalizers | High | Proven after narrowing the observation point to completed cancellation and cleanup |
| E22-P3 | Do lifecycle laws cover success, typed failure, defect, and cancellation exactly once? | Exit-kind generator plus ordered cleanup log | High | Proven; successful finalizers must emit explicit test logs because `Run` has no finalizer event seam |
| E22-P4 | Do primitive close/cancellation laws survive generated operation traces? | Model-based bounded traces and cancellation probes | High | Proven for the stated close fence and waiter-cancellation boundaries |
| E22-P5 | Can a tracked inventory resist prose/test drift? | One-line-per-law review inventory, source links, stable census, policy link | Medium | Proven for the initial inventory; semantic review remains necessary |

The policy is falsified if it can be satisfied by a property that does not run
both sides of the stated law, if an inventory law has no named property, or if a
passing property requires a stronger scheduler/finalizer claim than the mli
makes. Proof cost is not a falsifier.

### Observation equivalence

For this experiment, two effects are equivalent exactly when fresh
`Eta_test.Run.run` executions under the same explicit seed and equivalent
initial test clock produce:

1. the same normalized `Exit.t` (success values and typed failures compare as
   generated data; defects compare by rendered exception; cause constructors
   and order are preserved), and
2. the same ordered `Eta_test.Run.event` sequence, normalized only to remove no
   data that the public event records expose.

Per-category `logs`, `spans`, `metrics`, and `sleeps` are projections of the
ordered event stream and are not extra equality dimensions. Fiber census is a
side-condition for cancellation/leak properties, not part of general effect
equivalence. Mutable state, external I/O, wall time, arbitrary exceptions, and
nondeterminism hidden inside `Effect.sync` are outside the generated class.

Self-review: this equivalence is intentionally stronger than exit-only equality
and intentionally weaker than implementation-step equality. It can detect
duplicated/reordered observable work while allowing different private
interpretations. Lifecycle tests will make successful cleanup observable by
emitting log events; they will not pretend that `Run` has a production
per-finalizer event seam. Cancellation tests compare after the enclosing
combinator has completed and protected cleanup has run, never at an assumed
wall-clock deadline.

### Generator class

The algebraic generator will build finite, immutable blueprints from pure,
typed-failure, deterministic event-emitting, and bounded yield/delay leaves,
then apply at most three recursive levels chosen from `map`, `bind` with a small
enumerated total-function family, `bind_error`, `fold`, and lifecycle wrappers.
Generated values and functions are printable. Concurrency generators use short
finite schedules plus explicit `never` only where a winner/failure owns its
cancellation. Primitive generators use bounded operation traces over small
values and capacities. Schedule generators use nonnegative durations and valid
constructor parameters.

Arbitrary bind lambdas, arbitrary `sync` bodies, external resources, unbounded
recursion, wall-clock sleeps, and invalid constructor inputs are excluded. As in
E12, opaque functions are attacked separately with adversarial fixtures rather
than mislabeled as exhaustively generated.

### Expected refinements

1. **Fail-fast.** “Cancels the sibling” should mean cancellation is requested
   and the combinator waits through the sibling's cancellation-protected
   cleanup; it must not mean no sibling event can occur after the first failure
   or impose a scheduler-time bound.
2. **Race loser cancellation.** A loser may finish computation before the
   winner is observed, so the proof must force a genuinely pending loser and
   observe its finalizer. It must not infer cancellation from the winner alone.
3. **Monotone delays.** This is predicted to hold only for the monotone schedule
   constructors in their documented valid domain (`exponential`, `fibonacci`,
   and nonnegative `linear`), not for arbitrary `modify_delay`, jitter, fixed
   windows, or composed schedules.
4. **Monad laws.** Laws range only over total generated function families and
   the stated observation equivalence. OCaml effects or mutation hidden in a
   function would invalidate ordinary extensional function reasoning.
5. **Lifecycle all-exits.** Cancellation requires a structured parent that
   cancels a pending body. A root run of `never` is not a valid terminating
   sample.

If executable evidence shows public prose is stronger than these boundaries,
the exact counterexample and corrected mli wording will be recorded before an
mli edit.

### Predicted census and footguns

The initial inventory is predicted to contain **22 laws**:

| Mli | Predicted laws |
| --- | ---: |
| `lib/eta/effect.mli` | 17 |
| `lib/eta/schedule.mli` | 2 |
| `lib/eta/channel.mli` | 1 |
| `lib/eta/queue.mli` | 1 |
| `lib/eta/semaphore.mli` | 1 |
| **Total** | **22** |

The Effect count treats “each exit kind” as generated cases within one named law
for `finally`, one for `with_resource`, and one for override restoration; it
does not inflate the census by examples. Predicted inventory delta is **+22
tracked law rows / +22 named qcheck properties** from the pre-policy baseline.

Predicted new-footgun delta is **+0**. The likely traps—effect equivalence that
ignores events, vacuous same-side comparisons, arbitrary effectful bind
functions, scheduler deadlines, and invisible successful finalizers—must be
captured as review checks rather than introduced as product footguns. A real mli
violation found by adversarial testing will change the actual delta and be named
in the execution log.

### Prior recommendation

Predict **PROMOTE** only if all 22 inventory rows have non-vacuous named qcheck
properties, the deliberate vacuity probe is rejected, the two least-trusted laws
receive adversarial attacks, qcheck remains test-only, and every required Nix
gate passes. Otherwise HOLD/BLOCK rather than weaken the laws.

---

## Execution log

### V-DX-E22-001 — Predictions sealed

The prediction section above was committed before E22 implementation changes.

### V-DX-E22-002 — Observation and generated class implemented

Status: ACCEPT.

`test/laws/law_properties.ml` states the sealed boundary before any property:
diagnostically normalized `Exit.t` plus ordered `Eta_test.Run.event` from fresh
runs at explicit seed `0xE22`. Its equivalence helper removes the duplicate
per-category projections and fiber census before comparing complete `Run`
records; cancellation laws separately require `pending_fibers = Some []`.

The recursive depth-three blueprint generator has five base leaves and five
recursive wrapper/composition forms. Bind continuations come from a printable,
shrinkable three-member total-function family. Concurrency, primitive, schedule,
and exit inputs are bounded and printable. Arbitrary `sync`, external I/O,
unbounded recursion, and scheduler deadlines remain excluded as predicted.

### V-DX-E22-003 — Qcheck is test-only

Status: ACCEPT.

The new `test/laws/dune` executable links `qcheck` and
`qcheck-core.runner`; no installable package stanza or generated opam manifest
mentions qcheck. The flake provisions qcheck in the OxCaml setup path and the
mainline OCaml shell. The shipped OxCaml helper builds and runs `test/laws`.

Initial evidence before wiring was intentionally negative:

```text
nix develop -c ocamlfind list | grep -i qcheck
# exit 1, no matches
```

After wiring, the same command reports qcheck 0.91 and qcheck-core/runner 0.91.

### V-DX-E22-004 — Initial inventory executable

Status: ACCEPT for all 22 rows.

The tracked inventory in `review/LAWS.md` contains 17 Effect, two Schedule, one
Channel, one Queue, and one Semaphore law. Each row names an exact live qcheck
property. Fifty deterministic qcheck inputs per property produce 1,100 runner
inputs; the three all-exit properties execute all four exit kinds for every
input rather than relying on random case coverage.

Cancellation laws force pending work with `never` and a delayed owner, observe
exactly one cleanup log, and require an empty structured-fiber census. Channel
and Queue traces exercise both clean and error first-close wins, reject a future
blocking send and nonblocking send/offer, drain generated buffered values in
order, and observe the reason only after drain. Schedule monotonicity is limited
to valid exponential, fibonacci, and nonnegative linear inputs.

### V-DX-E22-005 — Refinements and counterexamples

Status: ACCEPT; no public prose edit required.

The five predicted boundaries were needed in the tests but did not contradict
the existing mli prose. Fail-fast and race are asserted at combinator completion
after protected cleanup, not at a scheduler deadline. Successful finalization is
made visible with ordinary log events because `Run` truthfully exposes no
per-finalizer event seam. Monad laws range over total generated functions, and
schedule monotonicity does not cover arbitrary delay modifiers or jitter.

One minimized counterexample was a test-construction bug, not an Eta violation:
scope LIFO shrank to resource list `[0; -1]` and showed that the first fixture
constructed acquisitions in reverse input order. `List.fold_right` corrected the
fixture so input-order acquisition now predicts reverse-order release.

Mainline OCaml 5.4 supplied a second build counterexample: `effect` is syntax in
that compiler, so local bindings accepted by OxCaml 5.2 failed at line 241. The
bindings were renamed `program`; the unchanged property then passed on both
compilers.

### V-DX-E22-006 — Red team

Status: ACCEPT.

`redteam/vacuous-property.md` records and rejects a deliberately green
self-comparison. The review inventory requires two separately stated sides,
while lifecycle and cancellation properties additionally require case matrices,
observable cleanup, and fiber census. Semantic review remains necessary; qcheck
cannot detect a maliciously disguised `true` generically.

The two least-trusted production laws—`par` fail-fast sibling cancellation and
Semaphore blocked-waiter cancellation safety—each passed 50 adversarial cases on
the unchanged implementation. No production violation was found. Full attack
shapes and verdicts are in `redteam/adversarial-laws.md`.

### V-DX-E22-007 — Census and policy actuals

Status: ACCEPT.

Actual census and property delta matched the sealed prediction: **+22 tracked
law rows / +22 named properties**, split 17/2/1/1/1 across the five mli files.
The sealed **+0 footgun** prediction was wrong: maintainer review found **+5
tracked follow-up footguns** outside the bootstrap (`review/LAWS.md`), including
two schedule model laws not yet stated in prose and existing all/with-scope,
Channel cancellation, and Semaphore bracket contracts not represented in the
initial 22. These are inventory gaps, not new product behavior. `AGENTS.md` now
requires a named qcheck property and same-change inventory update for every new
or changed mli law and explicitly rejects self-comparison as policy compliance.

The native Eio-backed `Eta_test.Run` suite is not a js_of_ocaml suite. Qcheck is
portable, but this observation engine depends on `eta_eio`/`Eio_main`; a JS law
suite would require a separate `eta_jsoo` observation engine. The suite was
instead run under both OxCaml and upstream native OCaml 5.4.

### V-DX-E22-008 — Independent maintainer review

Status: ACCEPT after fix-forward review.

The first independent review returned HOLD. It found lifecycle properties that
observed cleanup but not body-exit preservation/order; clock-only evidence for
the generic override laws; primitive traces too narrow for blocked Channel
waiters, Queue modes, and multi-permit Semaphore requests; schedule rows
overstated as existing prose; and one vacuity-document overclaim.

Fix-forward strengthened the same 22 properties: lifecycle matrices now assert
body exit, root exit, body-before-cleanup logs, and census; restoration/isolation
matrix clock, random, logger, and tracer; Channel checks blocked sender and
receiver wakeup; Queue runs all four modes within capacity; Semaphore runs every
valid request `1..capacity`; schedule provenance and five follow-up footguns are
explicit; and the vacuity control states that review, not `equivalent`, rejects
self-comparison. Re-review returned **READY** with no remaining must-fix finding.

### V-DX-E22-009 — Exact gates and recommendation

Status: ACCEPT / PROMOTE.

All objective gates passed from this worktree, along with focused law runs on
both native compilers:

```text
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws --force
```

Recommendation: promote the policy and initial suite. Keep FG-E22-001 through
FG-E22-005 visible until the bootstrap grows into a complete prose census.
