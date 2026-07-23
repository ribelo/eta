# DX-E15 Report — `Effect.interruptible`

Branch: `research/dx-e15-interruptible`

Recommendation: **READY FOR REVIEW**.

## V-DX-E15-005 — Decision and resumed history

DX-E15 ships `Effect.interruptible`. The original kill correctly rejected
`Cancel.protect` plus a descendant `Cancel.sub` and every scope/fork relay, but
incorrectly concluded that native Eio had no exact-context restore. Follow-up 1
supplied and independently reproduced a hidden same-fiber Eio switch operation.
Follow-up 2 then invalidated the first implementation: its restore binding was
fork-inherited even though the closure belonged only to the masking fiber. The
corrected implementation isolates the hidden operation in one native adapter
and makes all restoration state fiber-local.

The implementation now meets the one-pager gates:

- one mask model is stated within the public-interface budget;
- the cancellation-checkpoint list is published;
- native Eio and js_of_ocaml run the same named adversarial suite;
- mask-stack, at-most-once, and no-lost-wakeup claims have named evidence;
- finalizers, registered finalizers, and asynchronous cancelers forbid
  restoration;
- the canonical blocking accept victim is interrupted without changing fiber
  identity;
- masks cover children, restoration is fiber-local, and structured fail-fast
  remains prompt.

## V-DX-E15-006 — Phase 0 substrate truth and correction

The committed Phase 0 probes remain valid. `probes/native_probe.ml` prints:

```text
native parent->protect->sub: blocked_wait=returned protect=returned next_check=cancelled
native explicit-sub-cancel: escaped-protect=yes
native nested-protect: inner=returned outer=returned next_check=cancelled
native probe: PASS
```

`probes/jsoo_probe.ml` prints:

```text
jsoo nested-protect: depth=2 returned; depth=1 returned; depth=0 cancelled
jsoo pending-parent->protected-sub: child-wait=returned; protect-exit=cancelled
jsoo probe: PASS
```

These results prove that an Eio protected context is a propagation barrier and
that a `sub` created below it is not a restore. They also prove that jsoo keeps
cancellation pending at positive protection depth and delivers when the depth
returns to zero. The exact matrices and commands are in `phase0.md`.

The kill gate, not the observations, was wrong. A mask-entry Eio switch created
under the exact current context before protection gives this tree:

```text
C  exact current cancellation context
└─ R  mask-entry switch context
   └─ P  protected context
```

The hidden Eio core switch restore moves the current fiber from `P` to `R` and
back. Cancellation propagating `C → R` can therefore wake a blocked restored
operation while still stopping at `P`. The orchestrator's independent probe
reported `restore-during-block: DELIVERED` and
`restore-pending-entry: RAISED`. The implementation's accept victim and shared
suite reproduce both behaviors through the public combinator.

## V-DX-E15-007 — Contract and checkpoint documentation

The runtime contract adds the mask operation and a local-inheritance kind:

```ocaml
val with_cancel_mask : (cancellation_restore -> 'a) -> 'a
val create_local : ?inheritance:local_inheritance -> unit -> 'a local
```

The mask operation supplies same-fiber restoration to its parent context and
checks pending cancellation at entry and after a successfully returned callback.
The `Fiber_local` key kind is absent in forked children and daemons; existing
runtime locals remain fork-inherited by default. Eta stores `Restore`, `Restored`,
and `Restoration_forbidden` under one `Fiber_local` key.

The public `Effect.interruptible` contract states identity outside a mask,
innermost-wins stacking, entry/checkpoint/successful-exit delivery,
at-most-once observation, finalizer protection, and the corrected sentence:
restoration is fiber-local; children forked inside a mask remain masked.

`docs/api-dx.md` publishes the required checkpoint inventory. It covers explicit
yield, positive sleeps, unresolved promises and async park, blocking
channel/queue/pubsub/semaphore paths, structured-concurrency waits, native Eio
service waits, and JS host awaits. It also records immediate non-checkpoints and
the settled-promise backend difference.

## V-DX-E15-008 — Shared mask model and backend mapping

The shared dynamic model is:

- **masks cover children; restoration is fiber-local**;
- outside a mask, `interruptible e` is `e`;
- `uninterruptible` installs a restoration only for the calling fiber;
- `interruptible` invokes that fiber's nearest restoration and marks the dynamic
  region restored, so repeated `interruptible` is identity;
- a forked child inherits mask state but no restoration state, so its
  `interruptible` is identity;
- direct failure of the child's own structured scope remains interruptible and
  preserves fail-fast;
- daemons inherit neither restoration nor cleanup-forbidden state;
- a nested `uninterruptible` installs a fresh restoration and wins;
- cleanup establishes `Restoration_forbidden` only for its current fiber.

Native Eio creates `R` before entering `Cancel.protect`. Its private adapter is
the only repository implementation file that names the hidden Eio module. The
adapter captures callback values or exceptions plus raw backtraces across the
unit-returning same-fiber move, checks cancellation after successful callback
work, and moves back to the protected context. Eio is pinned by the repository;
upgrades must revalidate this internal dependency.

The jsoo backend saves the current `fiber_protect_depth`, sets it to zero,
checks cancellation, runs the callback, checks successful exit, and restores
the saved depth with `Fun.protect`. Ordinary children inherit the parent's depth;
daemons start at zero. A masked child listens separately for direct failure of
its own structured scope, matching native `Q` fail-fast without treating
ancestor cancellation as interruptible. Internal cleanup protection disables
that scope-failure path while joining children.

## V-DX-E15-009 — Finalizer answer

**No: restoration is forbidden in cleanup.** Allowing an inherited restoration
to escape protection would permit re-entrant cancellation to abort cleanup whose
completion Eta already promises to await.

`Effect_resource.run_cleanup`, registered runtime finalizers, and asynchronous
cancelers bind `Restoration_forbidden` before their existing protection whenever
an active restore is inherited. No extra binding is installed when no restore
exists. The marker has a boxed payload so it cannot alias another runtime-local
variant after representation erasure.

Shared tests on both backends prove that `interruptible` in `finally` cleanup and
in a registered finalizer remains protected until an explicit release. Existing
async-canceler protection uses the same helper.

## V-DX-E15-010 — Laws and named evidence

The E22 registry in `.scratch/research/dx/e22/review/LAWS.md` retains two direct
QCheck properties and now registers eight E15 effect claim clusters plus the
runtime-local inheritance contract.

| Claim | Named evidence | Native Eio | jsoo |
| --- | --- | --- | --- |
| Outside-mask identity | `interruptible outside a mask is identity for generated finite effects`; `interruptible outside a mask is identity` | PASS | PASS |
| Inner mask supersedes outer restore | `uninterruptible interruptible uninterruptible equals uninterruptible for generated finite effects`; `interruptible mask-stack law inner uninterruptible wins` | PASS | PASS |
| Innermost restoration wins | `interruptible nested mask innermost restore wins` | PASS | PASS |
| Repeated restore is identity | `repeated interruptible in restored region is identity` | PASS | PASS |
| Pending entry is delivered | `interruptible pending cancellation raises at restore entry` | PASS | PASS |
| Restored checkpoint/block is woken | `interruptible cancel at restored checkpoint is delivered`; `interruptible cancel during restored block wakes waiter` | PASS | PASS |
| Successful-exit edge is checked | `interruptible cancel between restore and exit hits successful boundary` | PASS | PASS |
| Entry races lose no wakeup | `interruptible generated cancel-mask-entry races lose no wakeup` | PASS | PASS |
| Delivery is at most once | `interruptible competing cancellation sources deliver once` | PASS | PASS |
| Finalizers cannot restore | `interruptible is forbidden in finalizers`; `interruptible is forbidden in registered finalizers` | PASS | PASS |
| Mask covers forked children | `cancellation mask covers forked children` | PASS | PASS |
| Forked child preserves fail-fast | `forked interruptible child preserves fail-fast` | PASS | PASS |
| Daemons discard restoration state | `daemon drops restore binding after mask`; `daemon drops cleanup-forbidden binding` | PASS | PASS |
| Local inheritance kinds are distinct | `runtime contract local inheritance kinds` | PASS | PASS |

The two QCheck properties execute both sides of each equation for generated
finite success/failure effect blueprints. Cancellation discrimination and all
race-sensitive claims use the same shared test definitions on both backends.

## V-DX-E15-011 — Race corpus

| Required race | Executable construction | Result on both backends |
| --- | --- | --- |
| Cancel during mask entry | Eight target/controller yield staggers around handle installation and entry | One interruption; no hang or lost wakeup |
| Cancel before restore entry | Cancel while masked, then enter `interruptible` | Entry raises |
| Cancel at checkpoint | Cancel a restored yield loop | Checkpoint raises |
| Cancel during restored block | Cancel an unresolved restored promise wait | Wait wakes and raises |
| Nested masks | Cancel an exact synthetic context enclosing the inner mask | Innermost restore wakes; outer model remains intact |
| Cancel between restore and exit | Cancel synchronously in the restored tail | Successful-exit check raises |
| Competing cancellation | Race distinct outer and inner cancellation contexts | One interrupt cause; finalizer runs once |
| Forked child fail-fast | Race masked `interruptible never` against a failing sibling | Prompt `Fail Boom`; child is interrupted through its own scope |

The runtime contract is same-domain except for explicitly designated wakeups.
After the successful-exit check, neither backend has a suspension point before
restoring the protected state, so same-domain cancellation cannot interleave in
that final interval.

## V-DX-E15-012 — Red-team outcomes

| Attack | Outcome against the implemented model |
| --- | --- |
| `protect` plus descendant `cancel_sub` | Refused; the Phase 0 probe proves the barrier. |
| Scope/fork cancellation relay | Refused; it loses exact synthetic-parent cancellation and changes fiber identity. |
| Entry/exit snapshots without restoring context | Refused; they cannot wake a blocked native service operation. |
| Pending cancellation before restore | Delivered by native switch entry and jsoo entry check. |
| Cancellation during restored synchronous tail | Delivered by both successful-exit checks. |
| Nested restoration accidentally selects outer mask | Refused by exact inner synthetic-context cancellation test. |
| Repeated restoration moves twice | Refused by the dynamic `Restored` marker. |
| Cleanup uses inherited restore | Refused by boxed `Restoration_forbidden`. |
| Fork inherits a parent restore | Reproduced as a native deadlock, then refused by `Fiber_local` binding state. |
| jsoo child starts at depth zero | Reproduced as premature interruption, then refused by depth inheritance. |
| Daemon outlives restore/forbidden state | Reproduced as `Switch finished` and masked cancellation, then refused by fork filtering. |
| Competing sources collapse to one handle | Replaced by distinct outer/inner cancellation contexts; one delivery remains. |
| Fork breaks reentrant ownership | No restore fork exists; Signal lane re-entry observes the same fiber ID before, during, and after restoration. |

Pre-fix reproduction evidence was exact: the critical native test exited 124
under a five-second bound; the native daemon produced `Switch finished`; the
cleanup daemon reached its bounded defect instead of interruption; and jsoo
reported `child forked inside mask was interrupted by default`. Each construction
is now a named shared regression on both backends. No lost-wakeup construction
remains against the corrected same-fiber model.

## V-DX-E15-013 — Review packet

`probes/accept_loop_victim.ml` runs a real loopback `Eio.Net.accept` inside
`Effect.uninterruptible`, wrapping only the accept in `Effect.interruptible`.
Cancellation targets the exact enclosing Eta synthetic context. Its completion
sentinels are:

```text
accept-loop-victim: INTERRUPTED
accept-loop-victim: PASS
```

`QUESTIONS.md` answers the review question “inside `uninterruptible`, when can
this fiber be cancelled?”, documents same-fiber identity and cleanup behavior,
and points reviewers to the shared suites. `docs/api-dx.md` contains the durable
mask model and checkpoint list. The Signal lane test is the fork-identity
adversary.

## V-DX-E15-014 — Census and footgun delta

| Census | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Public `Effect.interruptible` declarations | 0 | 1 | +1 |
| Runtime-contract mask operations | 0 | 1 | +1 |
| Backend mask implementations | 0 | 2 | +2 |
| Private native hidden-module adapters | 0 | 1 | +1 |
| Shared named adversarial cases | 0 | 16 | +16, run on each backend |
| Runtime-local inheritance kinds | 0 | 2 | +2 |
| Direct QCheck mask properties | 0 | 2 | +2 |
| Published cancellation-checkpoint sections | 0 | 1 | +1 |
| Committed probe/review executables | 0 | 3 | +3 |

The public footgun is explicit: `interruptible` is useful only around genuine
checkpoints in the same fiber that entered a dynamic mask; it does not make
synchronous work preemptible and cannot be inherited by children. Restoration in
cleanup is deliberately unavailable. A future child restore would need to
observe both parent mask-entry cancellation and the child's own fail-fast
context; that multi-context problem is parked. The remaining implementation risk
is the one isolated native internal-API dependency.

## V-DX-E15-015 — Prediction scoring

The original journal remains append-only, including the rejected kill and the
Follow-up 1 fork-inheritance error. Sealed prediction scoring remains **8 exact,
2 strengthened, 1 contradicted**:

- exact: Eio's protected-subtree barrier, explicit descendant cancellation,
  pending old-parent behavior, jsoo depth composition, jsoo innermost-wins,
  need for a native restore operation, finalizer prohibition, and entry/exit
  race pressure;
- strengthened: the checkpoint inventory and delivery-winner pressure;
- contradicted: the predicted kill after the search missed Eio's hidden
  same-fiber restore.

The first contradiction remains the missed hidden restore. Follow-up 2 adds a
post-prediction design error rather than changing that sealed score: same-fiber
restore was incorrectly assumed safe to fork-inherit. The corrected model makes
its ownership explicit and tests the invalidating constructions.

## V-DX-E15-016 — Gates and recommendation

The corrected Follow-up 2 bundle passed every prescribed gate:

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws test/js_jsoo test/cache_jsoo test/signal_jsoo --force` | PASS |

Mainline repeated the repository's two existing integer-overflow warnings while
compiling JS; every requested Node suite reached its completion sentinel. The
separately built native accept-loop victim also printed `INTERRUPTED` and `PASS`.
The implementation satisfies the one-pager and both follow-ups with the model:
**masks cover children; restoration is fiber-local**.

**E15 READY FOR REVIEW**
