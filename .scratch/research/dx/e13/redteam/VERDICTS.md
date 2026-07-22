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
settled-before-subscribe/park order. `async no lost wakeup under seeded
register/cancel races` runs twelve fixed scheduler-visible orderings on both
backends.

Verdict: **REFUSED**. The runtime promise is created before registration.
Resolution settles its latch; Eio `Promise.await` observes an already-settled
promise, while jsoo `subscribe` schedules the stored `Settled` result. There is
no condition-variable window, polling loop, timer fallback, or unqueued signal.

The fixed seeds are not simultaneous thread races. In single-threaded jsoo
there is no scheduler turn between an ordinary `register` return and the CPS
`await` effect installing its subscriber; a queued host microtask runs only
after that subscriber exists. Native callbacks may be cross-domain, but the
production linearization is the atomic state plus the runtime contract's
cross-domain `resolve_promise`, already covered by runtime-contract conformance.
The directly forceable pre-park case is synchronous settlement before any
subscriber exists; the seeds cover resolution-first and interruption-first
orders once the scheduler can run another task.

## C. Canceler blocks indefinitely

Attack:

```ocaml
Effect.async ~register:(fun _resume -> Some Effect.never)
```

Then interrupt the effect.

Verdict: **TRAP CONFIRMED BY CONTRACT**. Eta must wait because the canceler is
the host cleanup fence and runs uninterruptibly. A timeout or second interrupt
cannot safely pretend an event listener, timer, Promise abort, or C callback was
detached. The MLI and `docs/api-dx.md` therefore require cancelers to terminate;
Eta provides no fallback, silent detach, or timeout default. The bounded shared
case `async canceler is uninterruptible under second interrupt` proves the same
wait while eventually releasing the canceler, avoiding an intentionally hung
test process.
