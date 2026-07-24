# DX-E15 Journal

Branch: `research/dx-e15-interruptible`

## Sealed predictions

Sealed before any DX-E15 executable probe or implementation change. These
predictions are immutable; later findings and scoring are appended separately.

### Substrate predictions

1. **Native Eio protection is a subtree barrier.** Inside
   `Eio.Cancel.protect`, `Eio.Cancel.sub` creates an unprotected child of the
   protected context, not a restoration of the context outside `protect`.
   Cancelling the original parent will stop at the protected context and will
   not cancel that sub-context.
2. **Native explicit sub-cancellation still escapes.** If code explicitly
   cancels the sub-context created inside `protect`, a cancellable wait in that
   sub-context will raise `Cancel.Cancelled` through the outer protection.
   Protection blocks propagation from its parent; it does not catch arbitrary
   cancellation raised by a descendant.
3. **Native parent cancellation remains pending.** Eio's `protect` does not
   check its old parent on exit. The pending parent cancellation will be seen by
   a later cancellation check/checkpoint after the old context is restored,
   rather than necessarily at the return edge of `protect` itself.
4. **jsoo protection is an effective-depth mask.** Nested protection increments
   `fiber_protect_depth`; cancellation records `cancel_reason` but is delivered
   only when depth is zero. The current implementation checks after each
   protected callback, so only the exit that returns depth to zero delivers a
   pending cancellation. A protected unresolved await cannot be interrupted.
5. **jsoo can express innermost-wins locally.** An interruptible region can save
   a positive protection depth, make the effective depth zero, and restore the
   saved depth on exit. A nested `uninterruptible` then raises effective depth
   from zero and wins locally. Entry/exit checks will be needed to avoid losing
   cancellation at the transitions.

### Checkpoint predictions

- Core checkpoints will be `Effect.yield`, `Effect.sleep`/clock sleeps,
  runtime promise awaits (including the `Effect.async` park and
  `Effect.never`), and blocking runtime-stream operations.
- Eta channel, queue, semaphore, and signal waits will be checkpoints where
  they reduce to runtime promise/stream awaits. Immediate/nonblocking paths
  will not be checkpoints merely because the operation has a blocking sibling.
- Native blocking services inherited from Eio (including network accept and
  I/O, mutex/condition waits, and service-specific promise/stream waits) will be
  cancellable according to Eio's current cancellation context. jsoo host waits
  will be checkpoints only where their CPS continuation registers a cancellation
  waiter.
- `Effect.async` registration remains protected; its park is interruptible and
  its optional canceler remains protected.

### Mask-model and gate predictions

- The public model can be stated simply only as an innermost-wins dynamic mask:
  outside a mask `interruptible` is identity; inside one it restores parent
  cancellation at documented checkpoints; a nested `uninterruptible` masks
  again. Delivery is one-shot because the backend cancellation context retains
  one reason and each wait has one winning continuation.
- jsoo should admit that model with backend-local mask state. Native Eio will
  not admit it through `Cancel.protect` plus `Cancel.sub` alone. It will require
  either a new backend operation that can restore the context outside the
  protected subtree, or a relay fiber that observes original-parent
  cancellation and explicitly cancels interruptible descendants.
- A relay construction is predicted to introduce publication/removal races at
  mask entry and exit and to complicate blocking-service semantics beyond the
  roughly twelve-line interface budget. Unless probes reveal an existing Eio
  restoration mechanism, the predicted recommendation is **KILL** rather than
  ship a partially interruptible or lossy model.
- If promoted despite that prediction, the expected public census delta is one
  top-level `Effect` combinator and no application call-site migration. A new
  contract operation would also add one backend obligation. If killed, the
  public API delta is zero and the durable DX delta is the checkpoint list.

### Finalizer prediction

`interruptible` is not allowed to restore cancellation in Eta finalizers.
Finalizers run under protection so cleanup can settle after interruption;
restoring there would permit re-entrant cancellation to abort the cleanup that
the protection exists to guarantee. The predicted answer matches ZIO: **no**.

### Adversarial predictions

- Cancel-before-restore and cancel-during-restore-entry are the likely lost-
  wakeup boundaries. A valid construction must make pending cancellation
  observable before installing any cancellable park.
- Cancel-between-restore-and-exit must either interrupt the region or remain
  pending for the next outer interruptible checkpoint; it must not disappear
  when dynamic mask state is restored.
- Nested masks should be distinguishable only by the innermost active mask
  frame. In particular,
  `uninterruptible (interruptible (uninterruptible e))` should observe the same
  cancellation behavior as `uninterruptible e`.
- Delivery must be claimed once when cancellation races a successful wake; any
  design that can both return the wake result and later replay the same
  cancellation as a second delivery fails the gate.

## Phase 0 findings

### Executed substrate truth

Both assertion-bearing probes pass. Exact commands and outputs are in
`phase0.md`.

- Native confirmed predictions 1–3. Parent cancellation stops at
  `Cancel.protect` and does not reach a `Cancel.sub` below it. The blocked wait
  returns, `protect` returns, and the old parent's cancellation is raised only
  by the following explicit check. Explicitly cancelling the inner sub raises
  through protection.
- jsoo confirmed prediction 4. Cancellation remains pending at depths two and
  one; returning the outer protection to depth zero raises immediately.
- jsoo exposed an additional edge: a sub created under positive protection
  after its parent is already cancelled is intentionally not seeded with that
  reason (`propagate:false`). Its protected wait returns; restoring the parent
  and depth zero then raises.

### Restore constructions red-teamed

1. **`protect` + `cancel_sub`: refused.** Both probes show that a child made
   under protection is not a restoration of the context outside it.
2. **Entry/exit snapshots: refused.** A snapshot can see cancellation already
   pending, but cannot wake a network accept or promise wait when cancellation
   arrives after the snapshot.
3. **Scope relay: loses exact-parent cancellation.** Contract forks attach to a
   scope, while Eta cancellation can target a nested synthetic `cancel_sub`
   without cancelling that scope. Eio propagation stops at the protected
   context; the relay remains asleep and the proposed restored child remains
   blocked.
4. **One relay per synthetic context: out of scope and not small.** It requires
   changing the representation/behavior of `cancel_sub`, `cancel`, and every
   synthetic user, exactly the adjacent cancellation-surface redesign forbidden
   by the scope fence.
5. **Polling: refused.** It neither cancels arbitrary Eio service awaits nor
   states one checkpoint model, and would add latency/fallback behavior.
6. **Eio private-context move: unavailable.** Inspection is exposed, but the
   operations needed to attach to an arbitrary old context or move the running
   fiber are not.

The exact lost-wakeup construction is recorded in `phase0.md`. It cannot be
eliminated with the current contract. The Phase 0 gate therefore fires the kill
criterion before public docs, implementation, or law-bearing API prose is
introduced.

## Final decision

### Finalizer answer

Confirmed **NO**. `Runtime_core.run_finalizers` and
`Effect_resource.run_cleanup` protect cleanup deliberately. Restoring parent
cancellation inside cleanup would permit re-entrant cancellation to abort the
work that Eta is already obliged to settle and would undermine finalizer cause
composition.

### Prediction reconciliation

| Prediction | Score | Finding |
| --- | --- | --- |
| Eio protected subtree blocks parent propagation into inner sub | Exact | Native blocked-promise probe returned normally. |
| Explicit inner-sub cancellation escapes protection | Exact | Native yield raised the child reason through `protect`. |
| Eio old-parent cancellation waits for a later check | Exact | Both protections returned; following `Fiber.check` raised. |
| jsoo depth two/one suppresses and depth zero delivers | Exact | CPS probe produced exactly that trace. |
| jsoo can locally express innermost-wins | Exact at substrate level | Saving/resetting effective depth has the required local mapping; no API was implemented. |
| Native needs relay/new machinery and should kill if not simple | Exact | Exact-parent synthetic cancellation defeats a scope relay. |
| Finalizers must not restore | Exact | Both finalizer paths are protected in source. |
| Entry/exit boundaries contain the lost-wakeup pressure | Exact | A snapshot cannot wake a later blocked service operation. |
| Checkpoint list categories | Strengthened | Settled Eio promises and full jsoo stream adds add backend caveats. |
| Delivery winner pressure | Strengthened | Existing waits have winner protocols, but there is no valid restore on which to prove the new law. |

Score: **8 exact, 2 strengthened, 0 contradicted**.

### Kill verdict

The API, runtime contract, and production implementation remain unchanged. The
checkpoint list, executable probe record, report, and parking-lot prerequisites
land as the DX result.

### Final verification

All exact assignment gates pass on the final worktree:

```text
nix develop -c dune build @install                                      PASS
nix develop -c dune runtest --force                                     PASS
nix develop -c eta-oxcaml-test-shipped                                  PASS
nix develop .#mainline -c dune build --build-dir=_build-mainline @install PASS
nix develop .#mainline -c dune runtest --build-dir=_build-mainline \
  test/laws test/js_jsoo test/cache_jsoo test/signal_jsoo --force        PASS
```

The separate native and CPS Phase 0 probes also pass. Mainline repeated the two
existing integer-overflow warnings during JS compilation; all Node completion
sentinels were reached.

**E15 KILLED: Eio exposes no restore or arbitrary-parent cancellation observer;
scope-only relays lose cancellation of Eta synthetic sub-contexts and can strand
a blocked interruptible point.**

## Follow-up 1 — kill rejected, experiment resumed

The orchestrator rejected the kill with an independently reproduced hidden Eio
construction. This entry is append-only: the earlier reasoning remains above as
the record of the killed-then-resumed experiment.

### Explicit corrections

1. **“No restore” was false.** Eio's hidden core switch `run_in` operation moves
   the current fiber into a target switch cancellation context and back.
2. **“Every synthetic sub-context must be redesigned” was false.** Creating a
   mask-entry switch under the exact current context before protection preserves
   the cancellation edge from an enclosing Eta `cancel_sub`.
3. **“Private-context move unavailable” was false.** It is unavailable in the
   public Eio API inspected during Phase 0, but present in the hidden switch
   implementation.
4. The Phase 0 native matrix remains correct. It killed `protect + sub` and the
   relay construction, not the same-fiber switch construction.

### Verified model

Native mask entry creates `R` under exact current context `C`, then enters
protected child `P`. Restoration runs the same fiber in `R`, checks pending
cancellation on entry through the switch operation, preserves callback
exceptions/backtraces across the unit-returning boundary, and explicitly checks
after successful callback work before moving back to `P`.

jsoo saves the current protection depth, sets it to zero, checks cancellation at
entry, runs the callback, checks after successful work, and restores the saved
depth with `Fun.protect`.

The Eta layer installs each mask restore in a runtime-local binding. The binding
states are `Restore`, `Restored`, and boxed `Restoration_forbidden`:

- no binding: `interruptible` is identity;
- `Restore`: bind `Restored` and invoke the backend restore;
- `Restored`: repeated `interruptible` is identity;
- `Restoration_forbidden`: cleanup remains protected;
- nested `uninterruptible`: install a fresh restore unless cleanup has forbidden
  restoration, so the innermost mask wins.

Only `lib/eio/eta_eio_mask.ml` depends on the hidden Eio switch module. This is
an isolated internal-API dependency pinned to the repository's Eio version and
must be revalidated on upgrades. Upstream exposure is a human-owned external
follow-up.

### Finalizer decision

The sealed **NO** prediction stands. `Effect_resource.run_cleanup`, registered
runtime finalizers, and asynchronous cancelers establish restoration-forbidden
state before their existing protection when they inherit an active restore.
They do not pay for an extra binding when no restore exists. Shared native/jsoo
tests prove both `finally` cleanup and registered finalizers stay blocked until
explicitly released after parent cancellation.

### Adversarial reconciliation

| Construction/edge | Outcome against the real model |
| --- | --- |
| `protect + cancel_sub` | Still refused; Phase 0 proves it is not restore. |
| Scope/fork relay | Still refused; exact synthetic-parent cancellation is lost. |
| Cancel before restore entry | Entry check raises on both backends. |
| Cancel around mask entry | Eight generated scheduler staggers all terminate with one interruption. |
| Cancel during restored block | Pending promise and real Eio accept are woken. |
| Cancel at restored checkpoint | Both backends deliver. |
| Cancel in synchronous tail before restore exit | Successful-exit check delivers. |
| Nested masks | Exact inner synthetic-context cancellation reaches only the innermost restore target and wakes it. |
| Duplicate cancel | Exact single `Cause.Interrupt`; finalizer executes once. |
| Repeated restore | Dynamic `Restored` marker makes it identity. |
| Fork/identity concern | No fork exists; Signal lane nested re-entry keeps the same fiber ID. |
| Finalizer escape | Refused by boxed restoration-forbidden binding. |

No uneliminated lost-wakeup construction remains under the same-domain runtime
contract. After the successful-exit check there is no suspension point at which
same-domain cancellation can interleave before the native move back or the jsoo
depth restoration.

### Revised prediction scoring

The original score claiming zero contradictions is superseded.

| Prediction | Revised score | Finding |
| --- | --- | --- |
| Eio `protect` is a subtree barrier | Exact | Phase 0 probe still stands. |
| Explicit descendant cancellation escapes protection | Exact | Phase 0 probe still stands. |
| Eio old-parent cancellation stays pending | Exact | Phase 0 probe still stands. |
| jsoo depth composition and zero-depth delivery | Exact | Probe and implementation laws pass. |
| jsoo can express innermost-wins | Exact | Shipped depth save/zero/restore mapping. |
| Native needs a backend restore operation rather than `sub` | Exact | One new contract mask operation uses hidden `run_in`. |
| Finalizers must not restore | Exact | Two shared cleanup tests pass per backend. |
| Entry/exit boundaries carry lost-wakeup pressure | Exact | Entry, checkpoint, and successful-exit tests pass. |
| Checkpoint inventory | Strengthened | Real accept victim confirms service-I/O restoration. |
| Delivery winner pressure | Strengthened | Duplicate cancel and race corpus prove one delivery. |
| Predicted kill if probes found no existing restore | Contradicted | The search missed the hidden same-fiber primitive. |

Revised score: **8 exact, 2 strengthened, 1 contradicted**. The contradiction is
the reason E15 resumed.


### Resumed final gates

The final implementation and review bundle passed the complete prescribed set:

```text
nix develop -c dune build @install                                      PASS
nix develop -c dune runtest --force                                     PASS
nix develop -c eta-oxcaml-test-shipped                                  PASS
nix develop .#mainline -c dune build --build-dir=_build-mainline @install PASS
nix develop .#mainline -c dune runtest --build-dir=_build-mainline \
  test/laws test/js_jsoo test/cache_jsoo test/signal_jsoo --force        PASS
```

Mainline repeated the repository's two existing integer-overflow warnings while
compiling JS; the requested Node suites reached their completion sentinels. The
separately built real Eio accept-loop victim printed:

```text
accept-loop-victim: INTERRUPTED
accept-loop-victim: PASS
```

**E15 READY FOR REVIEW**

## Follow-up 2 — fork inheritance verdict rejected

The reviewer reproduced a critical deadlock and two backend/lifetime
divergences. The Follow-up 1 implementation incorrectly stored the restore in a
fork-inherited runtime local even though the closure belongs only to the fiber
that entered the mask.

### Reproduced before the fix

The minimal native regression was added first and run under an external five
second bound:

```text
nix develop -c timeout 5s dune exec test/core_eio/run.exe -- \
  test '^Effect interruptible$' 12
repro-exit=124
```

`uninterruptible (par (interruptible never) (fail `Boom))` hung exactly as
reported. The child moved from its own fail-fast context `Q` into the inherited
mask-entry restore context `R`; direct cancellation of `Q` could no longer wake
it.

Three additional pre-fix observations matched the review:

- native daemon after mask exit: `Invalid_argument("Switch finished!")`;
- native daemon forked during cleanup: cancellation stayed masked until the
  bounded test body died;
- jsoo child under `uninterruptible`: the mask-coverage regression reported
  `child forked inside mask was interrupted by default`.

The native mask-coverage regression already passed, confirming that native
cancellation-context lineage—not inherited restore state—covers children.

### Corrected model

**Masks cover children; restoration is fiber-local.**

The restoration key now uses the contract's `Fiber_local` inheritance kind.
Native Eio filters such bindings at every ordinary and daemon fork while keeping
all existing default-inherited runtime locals. jsoo does the same when copying
locals. `Restore`, `Restored`, and `Restoration_forbidden` are consequently
absent in every child and daemon.

A structured child inherits mask state, not the restore closure. Native obtains
that state from cancellation-context lineage. jsoo now copies the parent's
protection depth into ordinary children; daemons start independently at depth
zero. Verification found one additional substrate detail: inherited depth must
not suppress direct failure of the child's own structured scope. The jsoo
backend therefore keeps masked awaits subscribed to direct scope failure while
continuing to defer ancestor cancellation. Internal cleanup protection disables
that direct-failure subscription while it joins children.

The critical construction now returns `Cause.Fail Boom` promptly on both backends:
`interruptible` is identity in the forked child, parent cancellation remains
masked, and fail-fast cancellation of `Q` still wakes the child.

### Corrected adversarial corpus

The shared native/jsoo suite now also names:

- `forked interruptible child preserves fail-fast`;
- `cancellation mask covers forked children`;
- `daemon drops restore binding after mask`;
- `daemon drops cleanup-forbidden binding`;
- `interruptible competing cancellation sources deliver once`.

The at-most-once case now races two distinct cancellation contexts rather than
calling one idempotent handle twice. Contract-level native and jsoo tests prove
that ordinary locals retain their historical fork inheritance while
`Fiber_local` values are absent in children and daemons.

### Out-of-scope child restoration

A future child-restoring combinator cannot reuse its parent's restore closure.
It must observe both parent cancellation at the mask-entry context `R` and
direct fail-fast cancellation of the child's own context `Q`, with one winner
and no lost wakeup. That multi-context observation problem is parked rather
than implied by `Effect.interruptible`.

### Follow-up 2 final gates

The corrected implementation and review bundle passed the complete prescribed
set:

```text
nix develop -c dune build @install                                      PASS
nix develop -c dune runtest --force                                     PASS
nix develop -c eta-oxcaml-test-shipped                                  PASS
nix develop .#mainline -c dune build --build-dir=_build-mainline @install PASS
nix develop .#mainline -c dune runtest --build-dir=_build-mainline \
  test/laws test/js_jsoo test/cache_jsoo test/signal_jsoo --force        PASS
```

Mainline repeated the repository's two existing integer-overflow warnings while
compiling JS; all requested Node completion sentinels were reached. The
separately built native accept-loop victim printed:

```text
accept-loop-victim: INTERRUPTED
accept-loop-victim: PASS
```

**E15 READY FOR REVIEW**

## Follow-up 3 — restoration needs both ears

The reviewer found a same-fiber descendant topology that Follow-up 2 did not
cover:

```text
C → R → P → S
```

`R` is the mask-entry restore switch, `P` is the protected context, and `S` is
an Eta `cancel_sub` created inside the masked body before a nested
`Expert.eval (interruptible ...)`. Native `run_in R` moved the current fiber
away from `S`, so direct cancellation of `S` found no registered fiber. jsoo
kept the fiber in `S` while setting its effective protection depth to zero and
therefore already had the correct behavior.

### Reproduced before the fix

The new descendant-context regression hung on native under the external bound:

```text
nix develop -c timeout 5s dune exec test/core_eio/run.exe -- \
  test '^Effect interruptible$' 16
repro-exit=124
```

The Signal lane regression also failed before changing its depth-local policy:

```text
nix develop -c timeout 10s dune exec \
  test/signal/lane/test_eta_signal_lane.exe -- test '^lane$' 6
fork while lane held waits: FAIL
```

A child forked while its parent held the lane inherited positive depth and used
that depth as re-entry evidence, bypassing admission despite having a different
fiber identity.

### Corrected both-ears model

**A restore listens to the mask-entry parent `R` and the entry-time current
context `S`; the first cancellation wins and delivery is at most once.**

The native adapter now creates a scoped daemon relay while the current context is
still `S`, then moves the calling fiber to `R` with `run_in`. Cancellation of
`S` wakes the relay and forwards the reason to `R`; cancellation of `R` or its
parent reaches the restored fiber directly. Eio cancellation is idempotent, and
the scoped relay is disabled and stopped when restoration exits. A switch check
after a successful restored callback closes the race where `S` is cancelled
immediately before relay teardown.

The public contract adds the both-ears sentence without exceeding its roughly
twelve-line budget. The implementation cost is confined to the existing private
native adapter and adds no runtime-contract operation.

Three shared native/jsoo regressions name the descendant source, the mask-parent
source through the same topology, and the production-real signal-timer shape
with both sources competing while a finalizer counts at-most-once delivery.

### Signal lane decision

Cross-fiber lane re-entry is not intended. `graph_lane_depth_local` now uses the
contract's `Fiber_local` inheritance policy. Same-fiber nested `Expert.eval`
still sees positive depth and remains reentrant, while a forked child sees zero
depth and waits behind the held lane. The named fork-while-held regression also
proves that cancelling the waiting child does not enter the lane.

### Follow-up 3 final gates

The corrected implementation and evidence passed the complete prescribed set:

```text
nix develop -c dune build @install                                      PASS
nix develop -c dune runtest --force                                     PASS
nix develop -c eta-oxcaml-test-shipped                                  PASS
nix develop .#mainline -c dune build --build-dir=_build-mainline @install PASS
nix develop .#mainline -c dune runtest --build-dir=_build-mainline \
  test/laws test/js_jsoo test/cache_jsoo test/signal_jsoo --force        PASS
```

Mainline repeated the repository's two existing integer-overflow warnings while
compiling JS; all requested Node completion sentinels were reached. Targeted
verification also ran all nineteen shared interruptible cases on native, the
full shared jsoo adapter, and the fork-while-lane-held case. The separately built
native accept-loop victim printed:

```text
accept-loop-victim: INTERRUPTED
accept-loop-victim: PASS
```

**E15 READY FOR REVIEW**

## Follow-up 4 — cancellation-call ordering and teardown cost

Follow-up 3's asynchronous daemon relay delivered cancellation from both
contexts, but it did not preserve the ordering sentence it published. If `S`
was cancelled first and the mask parent second before the daemon ran, the parent
cancelled `R` directly and its reason became observable.

### Distinguishable-reason reproduction

The signal-timer regression now catches the backend cancellation exception
inside an `Expert` leaf before Eta intentionally erases its reason into
`Cause.Interrupt`. It uses distinct descendant and parent `Failure` values and
executes the two cancellation calls consecutively, descendant first. Before the
fix, the tight native command was deterministically red:

```text
nix develop -c timeout 10s dune exec test/core_eio/run.exe -- \
  test '^Effect interruptible$' 18
FAIL: signal-timer observed later cancellation reason
      Failure("interruptible parent cancellation")
```

The general competing-sources regression now also uses distinct inner and outer
reasons, calls inner then outer without a yield, and asserts the inner reason in
addition to one finalizer call.

### Synchronous-hook evidence and resolution

Eio's hidden cancellation machinery supports outcome **(a)**. In the pinned Eio
source, `Cancel.cancel` first marks the cancellation subtree and snapshots its
registered fiber contexts, then invokes every registered `cancel_fn` before the
call returns. `Cancel.Fiber_context.make`, `set_cancel_fn`, and `destroy` provide
registration and exact non-suspending lifetime management.

At restore entry the native adapter now:

1. checks pending cancellation in the current context `S`;
2. creates a synthetic fiber context registered under `S`;
3. installs a cancel function that synchronously cancels `R` with the same
   reason;
4. runs the calling fiber in `R` with `run_in`;
5. destroys the synthetic context on every exit.

The hook must not switch fibers and does not: nested `Cancel.cancel R` marks the
tree and invokes cancellation functions synchronously. Eio cancellation is
idempotent, so the reason from the first cancellation call executed is retained.
The previously red native case and all nineteen shared cases pass; the same
reason-ordering cases pass on jsoo.

### Teardown and cost correction

The Follow-up 3 report's claim that there was no suspension after the successful
body check was imprecise for that implementation: `Switch.run` still cancelled
and joined the daemon during teardown. The synchronous observer removes the
relay switch, daemon fiber, and shutdown scheduling cycle. Current observer
removal is a direct cancellation-list-node removal, so there is now no
suspension between the body check, observer destruction, and restoration of the
protected context.

Native per-restore cost is one synthetic fiber context (including a trace id and
one cancellation-list node), one cancel-function installation, and synchronous
destruction. The committed `restore_throughput.ml` watchlist probe warms up
10,000 restorations and times 100,000 successful
`uninterruptible (interruptible unit)` regions. Five runs in the OxCaml Nix
shell measured:

```text
1,835,501  1,830,359  1,829,289  1,820,966  1,844,850 restorations/second
```

Observed range: **1.82–1.84 million restorations/second**. This is evidence, not
a performance gate.

### Follow-up 4 final gates

The synchronous-observer implementation and corrected evidence passed the full
prescribed set:

```text
nix develop -c dune build @install                                      PASS
nix develop -c dune runtest --force                                     PASS
nix develop -c eta-oxcaml-test-shipped                                  PASS
nix develop .#mainline -c dune build --build-dir=_build-mainline @install PASS
nix develop .#mainline -c dune runtest --build-dir=_build-mainline \
  test/laws test/js_jsoo test/cache_jsoo test/signal_jsoo --force        PASS
```

Mainline repeated the repository's two existing integer-overflow warnings while
compiling JS; every requested Node completion sentinel was reached. The
separately built native accept-loop victim printed:

```text
accept-loop-victim: INTERRUPTED
accept-loop-victim: PASS
```

**E15 READY FOR REVIEW**

Cost-accounting clarification: the figure above isolates the new observer
machinery. The full native path also performs the entry check, the `run_in` move
to `R` and back, and the successful-body check; the mask-entry switch is paid
once per mask rather than per restoration. There is no suspension across that
check, move back, observer removal, and return from the restored dynamic region.

**E15 READY FOR REVIEW**
