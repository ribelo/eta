# DX-E13 Red-team Verdicts

The production evidence is the shared suite in
`test/core_common/effect_async_shared.ml`. It is instantiated by native Eio and
the Node CPS runner; the attacks below point to those executable cases rather
than maintaining a second semantic model in scratch code.

## A. Double resolution

Attack: call the supplied callback three times with `Ok 11`, `Ok 22`, then a
typed failure.

Evidence: `async one-shot first resolution wins` observes `Ok 11` and verifies
that all three callback attempts occurred. The second and third calls return
normally but cannot settle the runtime resolver.

Verdict: **REFUSED**. The sole `Async_pending -> Async_resolved exit` atomic
transition publishes the first exit. Every later compare-and-set fails before
`resolve_promise`.

## B. Resume, then park

Attack: invoke `resume` inline from `register`, before `register` returns and
before the Eta fiber calls `await_promise`. Seeded variants also resolve or
interrupt immediately after registration while the target is approaching its
park.

Evidence: `async synchronous resolution does not deadlock` forces the exact
settled-before-subscribe/park order. `async fixed same-domain resolution/cancel
orderings preserve wakeups` runs twelve deterministic scheduler-visible
orderings on both backends.

Verdict: **REFUSED**. The runtime promise is created before registration.
Resolution settles its latch; Eio `Promise.await` observes an already-settled
promise, while jsoo `subscribe` schedules the stored `Settled` result. There is
no condition-variable window, polling loop, timer fallback, or unqueued signal.

The fixed cases are not simultaneous thread races. In single-threaded jsoo
there is no scheduler turn between an ordinary `register` return and the CPS
`await` effect installing its subscriber; a queued host microtask runs only
after that subscriber exists. Native callbacks may be cross-domain, but the
production linearization is the atomic state plus the runtime contract's
cross-domain `resolve_promise`, already covered by runtime-contract conformance.
The directly forceable pre-park case is synchronous settlement before any
subscriber exists; the cases cover resolution-first and interruption-first
orders once the scheduler can run another task.

The native 32-trial test is named `async cross-domain
callback-vs-callback settles once`: two callback domains compete, and it does
not claim to race callback against cancellation. A cross-domain cancellation
trial would violate `Runtime_contract` itself: erased `cancel` is owner-domain
only, while `resolve_promise` is the explicit cross-domain wake operation.
Callback-versus-cancellation is therefore exercised by deterministic
owner-domain orderings rather than an invalid cross-domain `cancel` call.

## C. Canceler blocks indefinitely

Attack:

```ocaml
Effect.async ~register:(fun _resume -> Some Effect.never)
```

Then interrupt the effect.

Verdict: **TRAP CONFIRMED BY CONTRACT**. Eta must wait because the canceler is
the host cleanup fence and runs uninterruptibly. An outer timeout or pending
cancellation cannot safely pretend an event listener, timer, Promise abort, or
C callback was detached. The MLI and `docs/api-dx.md` therefore require
cancelers to terminate;
Eta provides no fallback, silent detach, or timeout default. The bounded shared
case `async canceler survives pending interruption across yields` proves that
the already-pending interruption does not preempt protected cleanup while the
canceler yields and waits. The controller eventually releases the canceler,
avoiding an intentionally hung test process.

## D. Retain `resume` after cancellation

Attack: let interruption win while `Effect.async` is awaiting its private jsoo
promise, then let host code retain `resume` indefinitely without calling it.

Before: the canceled CPS `Await` callback remained in `Pending callbacks`.
Because late `resume` calls are dropped by the async atomic state before promise
resolution, the promise could never settle and clear the callback. The retained
host callback therefore rooted the canceled continuation, fiber, and locals.

After: every jsoo promise subscription has an idempotent unsubscribe operation.
The `Await` handler invokes it synchronously when cancellation claims the
continuation, removing the subscription record from the still-pending promise
before scheduling discontinuation. The promise may remain pending, but retains
zero canceled continuations.

Evidence: `await cancellation removes promise subscription` times out a direct
`Eta_jsoo.Private.await`, observes the cancellation hook, then asserts
`Private.pending_subscriptions promise = 0`. This exercises the generic `Await`
handler used by `Effect.async`, `Effect.never`, and every runtime-contract
`await_promise`, so non-async pending awaiters receive the same hygiene. The
companion `throwing await cancel hook does not strand fiber` case proves that a
hook exception is resumed as a defect after unsubscription rather than
abandoning the waiter or scope shutdown.

Verdict: **REFUSED AFTER FIX**. Before the fix the regression test terminated
with one retained subscription; after the fix it observes zero.
