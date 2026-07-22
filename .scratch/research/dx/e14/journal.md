# DX-E14 Journal — sealed predictions

Sealed before E14 code changes. Later evidence will be appended without editing
this section.

## Question and proof obligations

Decide whether a three-value public `Eta.Promise` fence can preserve one-shot,
multi-waiter, cancellation, and scope-close semantics through one core
implementation on native Eio and js_of_ocaml CPS.

| Obligation | Minimum evidence | Risk | Predicted result |
| --- | --- | --- | --- |
| One-shot settlement | Conflicting repeated resolves and first-exit check | Medium | Proven on both backends |
| Cancellation-safe wait | Cancel one of two waiters, then resolve and re-await | High | Proven on both backends |
| Broadcast wakeup | At least three concurrent waiters | Medium | Proven on both backends |
| Scope-close interruption | Abandon a pending await at an Eta scope boundary | High | Proven by ordinary cancellation on both backends |
| Exit fidelity | Typed failure and defect exits round-trip through await | High | Proven on both backends |

## Mechanism predictions

The cell will own a synchronized state: unresolved with a set of active waiters,
or resolved with the winning full `Exit.t`. Each unresolved `await` will create a
promise/resolver pair from the active `Runtime_contract` and register its
resolver with the cell. `resolve` will commit the winning `Exit.t` under the
cell lock, detach all active waiters, then resolve each waiter through the
waiter's own contract. This permits different native owner domains while keeping
resumption on each waiter's runtime domain.

`await` and `resolve` will be ordinary core custom leaves created through the
audited internal effect-erasure bridge, not `Effect.Expert.make`. `await` will
return the stored `Exit.t` directly from its custom evaluator, preserving typed
failures, defects, interruption trees, and successful values without decoding
or re-raising them as another failure shape.

- **Native Eio:** each blocked waiter parks on its own `Eio.Promise`. The cell
  lock linearizes cancellation/removal against resolution. Contract resolution
  is the existing cross-domain-safe wake operation and Eio cancellation of the
  awaiting fiber enters the cleanup path.
- **jsoo CPS:** each waiter parks through the existing removable `Await`
  subscription. Cancellation synchronously unsubscribes that continuation;
  cell cleanup also removes the waiter record. Settlement schedules every
  remaining subscription, and a later await reads the stored exit immediately.
- **N awaiters:** resolution snapshots every active waiter after the state
  commit and wakes all of them; no waiter consumes the value.
- **Boundary close:** a pending `await` is interrupted by the ordinary
  scope/cancellation path. Native cancellation unwinds `Eio.Promise.await`; jsoo
  cancellation removes the CPS subscription before discontinuation. No Promise
  specific close operation or hidden daemon is predicted.

## Edge predictions

- **Resolve after all waiters' scope closes:** the cell itself is not scoped.
  Cancelled waiters are absent, but the first later `resolve` still returns
  `true`, stores the exit, and a later await succeeds immediately. A second
  resolve returns `false`.
- **Resolution racing waiter cancellation:** the cell lock is the linearization
  point. If cancellation removes the waiter first, that waiter remains
  interrupted and resolution still settles the cell for other/later waiters. If
  resolution commits first, the waiter observes the committed exit. In neither
  order can cancellation consume or clear the cell value.
- **Abandoned fiber:** structured scope close cancels its pending await and
  removes both the cell waiter and (on jsoo) the underlying CPS subscription.
  A fiber retained by a still-open scope remains intentionally live.
- **Who may resolve:** any fiber with the cell may attempt resolution; the type
  does not encode resolver ownership. The boolean makes losing attempts visible.

## Hypothesis ledger

| Candidate | Strongest case | Falsifier | Predicted status |
| --- | --- | --- | --- |
| A. One public core wrapper over runtime-contract promises | H-W4 portability fence with one shared contract | Shared cancel/close tests diverge | Accept |
| B. Separate native and jsoo Promise modules | Could expose substrate-specific cleanup | One shared core state and tests suffice | Dominated |
| C. Keep applications on `Expert.make`/naked `Eio.Promise` | Adds no public surface | Review fixture shows unavoidable backend/runtime machinery | Reject |

## Sealed quantitative predictions

- Concurrency/data primitive cluster: **+1 public module** (`Promise`).
- Public surface: **+3 values** (`create`, `await`, `resolve`) and one abstract
  type constructor.
- New footguns: **+0**. Resolver authority and resolve-after-close are explicit
  documented edges; the visible `bool` prevents silent duplicate resolution.
- Application call-site improvement: **5/5**.
- Cancellation contract clarity: **at least 4/5**.
- Two-substrate confidence after shared tests: **at least 4/5**.

## `Eta_test.Async` prediction

Predicted decision: **hold**. `eta_test` is intentionally Eio-backed and its
`Async` helpers synchronously fork and await host test fibers outside an Eta
effect evaluation. Replacing their `Eio.Promise.t` with `Eta.Promise.t` would
make `await` effectful and require an active Eta runtime, changing the helper's
role rather than merely removing a portability leak. This prediction will be
checked against its implementation, callers, and the jsoo test track.

## What would kill promotion

Kill if one shared implementation cannot make scope cancellation remove a
waiter without consuming settlement on either backend, or if faithful `Exit.t`
delivery requires backend-specific interpreters/polyfills.

---

# Implementation and evidence follow-up

## Implemented slice

The implementation matches candidate A and the sealed mechanism. `Promise.t`
owns a `Sync_lock`-protected `Pending waiters | Settled exit` state. Every
pending awaiter owns a promise/resolver pair from its active runtime contract.
The winning resolution stores the full exit under the lock, detaches all
waiters, then wakes them through their own contracts. `Effect_erasure` gained
one internal `public_runtime` bridge so the public module can define custom core
leaves without exposing or consuming `Effect.Expert`.

Cancellation catches only runtime-recognized cancellation. It reacquires the
cell lock: pending state removes that waiter and re-raises interruption; settled
state returns the authoritative exit. A non-cancellation backend defect removes
the pending waiter and propagates normally. No backend-specific Promise code,
new runtime-contract field, polling loop, timer, daemon, fallback, or polyfill
was added.

## Focused evidence

The six programs in `test/core_common/promise_shared.ml` are instantiated
unchanged for native Eio and Node CPS:

- `promise one-shot first exit preserved`;
- `promise three waiters wake`;
- `promise cancelled waiter does not consume`;
- `promise boundary close interrupts waiter`;
- `promise resolution before cancellation still delivers`;
- `promise error and defect exit fidelity`.

Both focused commands passed. The Node runner reached its `eta_jsoo ok`
completion sentinel. The resolution-first race is a deterministic ordering, not
simultaneous cross-domain stress; cancellation-first is forced by waiting for
the cancelled waiter to complete before resolution. Together they prove both
semantic winners on both substrates.

Review fixtures `coord-old.ml` and `coord-new.ml` each type-check against the
local built interface (the required hyphenated filenames produce only OCaml's
bad-module-name warning). They are 14 and 16 lines respectively.

## `Eta_test.Async` decision

**HOLD; do not migrate.** `eta_test` deliberately links `eta_eio`, `eio`, and
`eio_main`. Its `Async.fork_run`, `await`, `unresolved`, and `yield` are host-test
helpers that fork and block synchronously outside an Eta effect evaluation.
`Eta.Promise.await` is effectful and requires an active Eta runtime; substituting
it would change those helper contracts rather than remove a transparent type
leak. The jsoo Promise track instead links the portable shared suite directly
and does not link `eta_test`. This matches the sealed prediction and the scope
fence against migrating native-only tests.

## Census and footguns

| Census | Before | Predicted | Actual | Delta |
| --- | ---: | ---: | ---: | ---: |
| Root `lib/eta/*.mli` files | 28 | 29 | 29 | **+1** |
| Concurrency/data cluster modules | 12 | 13 | 13 | **+1** |
| `Promise` public values | 0 | 3 | 3 | **+3** |
| New footguns | 0 | 0 | 0 | **+0** |

The documented edges are not counted as new footguns: any holder may attempt
resolution; losing attempts return `false`; cancellation and resolution follow
first-commit ordering; and an owning cancellation boundary removes waiters but
does not close the cell.

## Red-team and review outcomes

All four red-team attacks were refused with shared executable evidence; details
are in `redteam/VERDICTS.md`. Independent API review first found three evidence
clarity gaps. The MLI now states cancellation/resolution ordering,
`coord-new.ml` checks its resolution result loudly, and the manifest records
focused outcomes. Re-review ratings are 5/5 for call-site improvement, 5/5 for
MLI cancellation clarity, and 5/5 for two-substrate confidence, matching or
exceeding sealed predictions.

Hypothesis ledger result:

- **A. One public core wrapper: ACCEPTED.**
- **B. Separate backend modules: DOMINATED.** Shared implementation and tests
  passed unchanged.
- **C. Keep applications on Expert/naked Eio: REJECTED for portable code.** The
  review fixture exposes runtime context, scope, contract, resolver, fork, park,
  and exit plumbing. Naked `Eio.Promise` remains accepted for Eio-only code.

## Exact gates

All required commands passed on the final implementation, with every mainline
command using `_build-mainline`:

```text
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo test/cache_jsoo test/signal_jsoo --force
```

The mainline test gate repeated the repository's pre-existing two
integer-overflow warnings; all requested suites completed successfully.

## Deviations and remaining uncertainty

No contract or scope deviation. The checkout was initially registered by Git at
`/tmp/Eta-dx-e14` while the assigned path contained only `objective.md`; it was
moved with `git worktree move` to the objective's required path before changes.
The suite does not claim simultaneous cross-domain cancellation stress because
contract cancellation is owner-domain-only and jsoo is single-domain. Nor does
the public MLI claim cross-runtime/domain sharing. The linearized
cancellation-first and resolution-first orders are the portable proof.
