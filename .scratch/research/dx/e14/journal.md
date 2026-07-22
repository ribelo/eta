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
