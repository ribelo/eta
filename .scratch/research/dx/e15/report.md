# DX-E15 Report — `Effect.interruptible`

Branch: `research/dx-e15-interruptible`

Recommendation: **KILL**.

## V-DX-E15-005 — Decision

`Effect.interruptible` is not added. Eio's protected cancellation context is a
propagation barrier, and a `Cancel.sub` beneath it remains protected from the
context that the proposed combinator must restore. The current Eta/Eio contract
cannot subscribe a restored child to the exact old context.

The precise inexpressibility is:

> A scope-only relay cannot observe explicit cancellation of an enclosing Eta
> synthetic `cancel_sub`. That cancellation stops at `Eio.Cancel.protect`, so a
> proposed interruptible descendant can remain blocked forever. Eliminating the
> lost wakeup requires an Eio restore/observer primitive or a redesign of Eta's
> cancellation handles and every synthetic sub-context.

This fires two honored kill criteria: an uneliminated lost-wakeup construction,
and native contract machinery that cannot remain a small mask operation shared
with jsoo.

## V-DX-E15-006 — Phase 0 substrate truth

The executable sources, reproduction commands, full outputs, and matrices are
in `probes/` and `phase0.md`.

Native Eio assertions establish:

- parent cancellation does not cross `Cancel.protect` into a `Cancel.sub`
  descendant, even while that descendant blocks on a promise;
- explicit cancellation of the descendant does raise through protection;
- nested protections return normally, and Eio sees the pending old-parent
  cancellation at the next check after the outer return.

jsoo CPS assertions establish:

- cancellation remains pending at protection depths two and one;
- returning protection to depth zero checks and raises the pending reason;
- a sub created under positive protection after parent cancellation is not
  seeded with that reason, but returning to the parent at depth zero raises.

Both probes print `PASS` and use a Node completion sentinel for the CPS case.

## V-DX-E15-007 — Checkpoint documentation

The required checkpoint list is published in `docs/api-dx.md` under
“Cancellation Checkpoints.” `phase0.md` contains the source-level inventory and
backend matrix.

It covers explicit yield and positive sleeps, pending promises and async park,
blocking channel/queue/pubsub/semaphore paths, structured-concurrency and
package-internal waits, native Eio service waits, and JS host awaits. It also
records non-checkpoints and the resolved-promise fast-path difference: Eio can
return an already-resolved promise without checking cancellation, while jsoo
checks before its await.

This documentation is the durable DX result even though the combinator is
killed.

## V-DX-E15-008 — Candidate mask model and backend mapping

The candidate user model itself is short:

- masks are dynamically nested and the innermost mask wins;
- `interruptible` outside a mask is identity;
- inside `uninterruptible`, it restores parent cancellation only at documented
  checkpoints;
- a nested `uninterruptible` masks again;
- finalizers never restore cancellation.

jsoo can map this model locally by saving a positive protection depth, making
the effective depth zero for the interruptible body, and restoring the saved
depth. A nested protection increments from zero and therefore wins.

Native Eio has no corresponding mapping. `Cancel.protect` changes the fiber's
current context to a protected child. `Cancel.sub` can only create another child
of that protected context. Inspection can detect an already-cancelled old
context, but it cannot wake a service operation when cancellation arrives after
the inspection.

A watcher attached to `Runtime_contract.scope` is insufficient because the
exact current parent can be a separately cancelled synthetic context. Adding a
watcher to every synthetic context changes `cancel_sub`, `cancel`, blocking,
supervisor, signal, and async cancellation machinery. That is a cancellation-
surface redesign, not the smallest E15 change, and still differs fundamentally
from jsoo's depth mapping.

The two backends therefore cannot implement one stated model on their current
substrates.

## V-DX-E15-009 — Finalizer answer

**No.** A revived `interruptible` must not restore cancellation in a finalizer.

`Runtime_core.run_finalizers` and `Effect_resource.run_cleanup` deliberately run
cleanup under `Runtime_contract.protect`. Cleanup is already executing because
an exit—possibly cancellation—must settle. Restoring parent cancellation would
permit re-entrant cancellation to abort that cleanup and invalidate Eta's
finalizer/suppressed-cause guarantees. This agrees with the sealed prediction
and ZIO's answer.

No finalizer behavior changes on this branch.

## V-DX-E15-010 — Laws and race corpus

No law-bearing `Effect.interruptible` interface is added, so no E22 registry row
or property is claimed green. Phase 2 correctly did not run after the Phase 0
kill gate.

The Phase 0 executable assertions are named in source:

- native: `parent_cancel_during_sub`,
  `explicit_sub_cancel_escapes_protect`, and
  `nested_protect_parent_cancel`;
- jsoo: `nested_protect_probe` and `sub_after_pending_probe`.

The required future property/race corpus remains parked, not falsely reported as
implemented:

| Corpus case | Current outcome |
| --- | --- |
| cancel-during-mask-entry | Entry snapshots cannot cover cancellation arriving during a later blocked native wait. |
| cancel-at-checkpoint | jsoo depth zero can deliver; native descendant remains behind the protected barrier. |
| nested masks / innermost wins | Locally expressible in jsoo; no native restore mapping. |
| cancel-between-restore-and-exit | Scope relay can miss exact-parent synthetic cancellation; exit inspection cannot wake the already-blocked operation. |
| delivery at most once | Existing backend waits have winner protocols, but no shared restore exists on which to prove the new law. |

## V-DX-E15-011 — Red-team outcomes

| Attack | Outcome |
| --- | --- |
| `protect` plus inner `cancel_sub` | Refused by both probes as a restore. |
| Check cancellation only at interruptible entry/exit | Loses cancellation arriving while a native service await is blocked. |
| Relay cancellation from the Eta scope | Loses explicit cancellation of a nested synthetic parent while the scope stays live. |
| Add a relay to every synthetic context | Requires the forbidden adjacent cancellation-surface redesign. |
| Poll the old context | Cannot interrupt arbitrary blocking Eio operations and adds fallback latency. |
| Use Eio private context APIs | They expose inspection/current suspension hooks, not moving the running fiber or attaching a watcher to an arbitrary old context. |

The scope-relay row is the uneliminated lost-wakeup kill input.

## V-DX-E15-012 — Census and footguns

| Census | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Top-level `Effect.interruptible` declarations | 0 | 0 | 0 |
| Runtime-contract mask operations | 0 | 0 | 0 |
| Production implementation lines | 0 | 0 | 0 |
| Published cancellation-checkpoint sections | 0 | 1 | +1 |
| Committed backend probe executables | 0 | 2 | +2 |
| New public footguns | 0 | 0 | 0 |

The inventory makes two existing substrate edges visible rather than adding
footguns: settled-promise checkpoint behavior differs, and Eio protection does
not check its old parent on exit.

## V-DX-E15-013 — Prediction scoring

The sealed journal predicted all decisive outcomes:

- exact: Eio's protected-subtree barrier, explicit descendant cancellation
  escaping, and pending old-parent delivery at the next check;
- exact: jsoo depth composition and delivery when depth returns to zero;
- exact: jsoo's local innermost-wins mapping is expressible;
- exact: native requires relay/new cancellation machinery and fires the kill;
- exact: finalizers must not restore cancellation;
- exact: cancel-during-entry/exit is the lost-wakeup pressure point.

Two checkpoint details were additional evidence rather than sealed predictions:
the settled Eio promise fast path does not check cancellation, and jsoo protects
a full runtime-stream add. No prediction was contradicted.

Score: **8 exact, 2 strengthened by additional evidence, 0 contradicted**.

## V-DX-E15-014 — Gates and recommendation

The Phase 0 native and jsoo probes pass. The complete prescribed gates were also
run on the final documentation/kill bundle:

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws test/js_jsoo test/cache_jsoo test/signal_jsoo --force` | PASS |

The mainline compiler emitted the repository's existing two integer-overflow
warnings while compiling JS. All requested Node suites reached their completion
sentinels. These baseline gates prove the kill bundle does not regress the
repository; they do not imply law coverage for an API that was not added.

The parking-lot prerequisites are in `PARKING_LOT.md`.

**E15 KILLED: Eio exposes no restore or arbitrary-parent cancellation observer;
scope-only relays lose cancellation of Eta synthetic sub-contexts and can strand
a blocked interruptible point.**
