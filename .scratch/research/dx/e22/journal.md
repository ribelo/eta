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
