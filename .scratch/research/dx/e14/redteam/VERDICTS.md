# DX-E14 Red-team Verdicts

The production evidence is the single shared suite in
`test/core_common/promise_shared.ml`, instantiated by native Eio and Node CPS.

## A. Cancel one waiter, then resolve

Attack: register two waiters, cancel one to completion, resolve `Ok 23`, then
await the cell again.

Evidence: `promise cancelled waiter does not consume` observes interruption for
the cancelled waiter, `23` for the live waiter, `true` from resolution, and `23`
from the later await.

Verdict: **REFUSED**. Cancellation removes only its waiter record. On jsoo the
underlying `Await` handler also synchronously unsubscribes the CPS continuation
before discontinuation is scheduled.

## B. Resolve twice with conflicting exits

Attack: resolve `Ok 11`, then attempt a typed failure.

Evidence: `promise one-shot first exit preserved` observes `true`, then `false`,
then `11` from await.

Verdict: **REFUSED**. The synchronized `Pending -> Settled exit` transition is
the sole commit point; losing attempts never reach a runtime resolver.

## C. Abandon an awaiting fiber

Attack: start a pending await as body-owned background work, then let the body
return without resolving the promise.

Evidence: `promise boundary close interrupts waiter` observes the background
finalizer before continuing, then resolves the still-usable cell and re-awaits
its value. The existing jsoo regression `await cancellation removes promise
subscription` directly observes zero retained subscriptions after cancellation.

Verdict: **REFUSED AT A STRUCTURED BOUNDARY**. Scope close follows ordinary Eta
cancellation, removes the Promise waiter, and receives E13's jsoo subscription
hygiene. A fiber deliberately retained by a still-open scope remains live; the
cell does not invent a timeout, weak reference, or hidden daemon.

## D. Resolve, then cancel before the waiter resumes

Attack: commit `Ok 41`, immediately request waiter cancellation, and allow the
scheduler to resume it afterward.

Evidence: `promise resolution before cancellation still delivers`
deterministically forces this order on both backends and observes `41`.

Verdict: **RESOLUTION WINS AFTER COMMIT**. If cancellation had acquired the cell
lock first it would remove the waiter and remain interrupted; after settlement,
the stored exit is authoritative even if the backend await surfaces cancellation
before its scheduled wake callback.
