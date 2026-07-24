# DX-E15 Phase 0 — substrate truth

Date: 2026-07-23

The probes in `probes/` ran before any production or public-interface change.
They assert their observations and exit nonzero on a mismatch.

## V-DX-E15-001 — Native Eio probe

Command:

```sh
nix develop -c dune exec \
  --root .scratch/research/dx/e15/probes ./native_probe.exe
```

Output:

```text
native parent->protect->sub: blocked_wait=returned protect=returned next_check=cancelled
native explicit-sub-cancel: escaped-protect=yes
native nested-protect: inner=returned outer=returned next_check=cancelled
native probe: PASS
```

### Propagation/protection matrix

| Construction | Result |
| --- | --- |
| Cancel the context outside `Cancel.protect`; block in an unprotected `Cancel.sub` created inside it | The blocked promise wait returns. Parent cancellation does **not** reach the sub. |
| Return from the sub and outer `protect` after that parent cancellation | Both return normally. Eio `protect` does not check the old parent on exit. |
| Explicit `Fiber.check` after `protect` restores the cancelled old parent | Raises `Cancel.Cancelled` with the original reason. |
| Explicitly cancel the sub created inside `protect`, then yield | `Cancel.Cancelled` raises through the outer `protect`. Protection is a propagation barrier, not an exception catcher. |
| Two nested `protect` calls; cancel their old parent | Both protected bodies return; the first explicit check after the outer return raises. |

This matches Eio 1.3+ox's implementation and documentation:

- `Cancel.protect` creates a protected child cancellation context;
- recursive parent cancellation stops at protected children;
- `Cancel.sub` creates an ordinary child of the **current** context;
- `protect` deliberately does not check its old parent on exit.

Therefore `Cancel.sub` under `Cancel.protect` is another descendant of the
barrier. It is not a restore operation.

## V-DX-E15-002 — js_of_ocaml CPS probe

The command in `probes/README.md` builds and installs this worktree to a
temporary prefix, then compiles the separate probe with `--effects=cps`.

Output:

```text
jsoo nested-protect: depth=2 returned; depth=1 returned; depth=0 cancelled
jsoo pending-parent->protected-sub: child-wait=returned; protect-exit=cancelled
jsoo probe: PASS
```

### Depth/context matrix

| Construction | Result |
| --- | --- |
| Cancel at `fiber_protect_depth = 2`, then yield | The yield returns; no cancellation waiter is installed while protected. |
| Return the inner protection to depth 1 | Returns normally. |
| Return the outer protection to depth 0 | `protect_impl` calls `check_cancel` and raises the pending reason at that return edge. |
| Cancel a parent, then create `cancel_sub` while protection depth is positive | `add_cancel_child ~propagate:false` does not seed the child with the already-pending reason; its protected yield returns. Restoring the cancelled parent and returning protection delivers the reason. |

The source boundary is `lib/jsoo/eta_jsoo.ml`:

- `check_cancel` raises only for `cancel_reason = Some _` and depth zero
  (lines 161–164);
- an `Await` installs a cancellation waiter only at depth zero (lines 235–267);
- `protect_impl` increments/decrements depth and checks after the decrement
  (lines 295–310);
- `cancel_sub` suppresses initial propagation under protection
  (lines 462–472).

jsoo could represent an innermost interruptible region by saving a positive
depth, making the effective depth zero, and restoring the saved value. A nested
protection would then increment from zero and mask again. That mechanism does
not exist in the current contract, but it is locally expressible.

## V-DX-E15-003 — checkpoint inventory

A checkpoint below means a call at which already-pending cancellation is
checked or a pending operation installs a cancellation wakeup. A function is
not a checkpoint merely because a sibling path can block.

### Backend primitives

| Primitive | Native Eio | js_of_ocaml CPS |
| --- | --- | --- |
| `yield` | Always suspends, then checks its current context. | Awaits a queued task; `await` checks before suspension and installs a waiter at depth zero. |
| positive `sleep` | Eio clock sleep is cancellable while pending. Non-positive Eta sleeps return directly. | Timer promise await is cancellable at depth zero and clears the timer on cancellation. Non-positive sleeps return directly. |
| `check` | Immediate `Fiber.check`. | Immediate `check_cancel`. |
| unresolved `await_promise` | Registers an Eio cancellation function while suspended. | Checks before `Await`, unsubscribes the promise continuation, and discontinues it on cancellation. |
| already-resolved `await_promise` | Eio returns the value without a cancellation check. | `await` checks before observing/scheduling the settled result. Do not use a settled promise as a portable checkpoint. |
| blocking `stream_take` | Cancellable Eio waiter. | Promise await at depth zero. |
| immediate `stream_take` / `stream_take_nonblocking` | No checkpoint. | No checkpoint. |
| blocking `stream_add` | Its Eio waiter can be cancelled after blocking; the implementation uses an unchecked entry to preserve the committed add protocol. | The full-stream wait is deliberately protected. It is not an ordinary interruptible checkpoint. |
| `await_cancel` | Suspends until its current context is cancelled. | Registers directly with the current cancellation context, then raises the reason. |

### Eta public and package surfaces

- `Effect.yield` is an explicit checkpoint.
- Positive `Effect.sleep` and the sleep before `Effect.delay` are checkpoints.
  Timer legs used by timeout, retry, repeat, schedules, and resource refresh
  inherit the active clock's blocking checkpoint. A non-positive live-backend
  sleep is not a checkpoint.
- `Eta.Promise.await` is a checkpoint while its backend promise is unresolved.
  Its settled fast path has the backend difference recorded above.
- `Effect.async` registration is protected through return, its unresolved
  promise park is a checkpoint, and its optional interruption canceler is
  protected. `Effect.never` is an unresolved promise checkpoint.
- Blocking handoff paths are checkpoints: full `Channel.send`, empty
  `Channel.recv`; full backpressure `Queue.offer`/`send`, empty `Queue.take`,
  `Queue.await_shutdown`; full backpressure `Pubsub.publish`, empty
  `Pubsub.recv`; and waiting `Semaphore.acquire`. Their immediate paths are not
  checkpoints. `Channel.try_send`/`try_recv`, `Queue.try_offer`/`poll`,
  `Pubsub.try_recv`, snapshots, and other nonblocking probes are not
  checkpoints.
- Structured-concurrency coordination blocks through runtime promises/streams:
  `race`, `all`/`all_settled`/parallel collection, supervisor child await,
  background/scope shutdown, and runtime daemon drain. Only their actual waits
  are checkpoints; an already-available result is not a portable checkpoint.
- Pool slot contention cooperatively calls runtime `yield`; pool shutdown,
  cache load coalescing, signal graph-lane grants, stream drain counters, and
  blocking-pool admission/job results use runtime promise/`await_cancel` waits.
- Native Eio-only services inherit Eio checkpoints wherever they actually
  block: listener accept/connect, flow read/write/copy, unresolved Eio promises,
  empty/full Eio streams, mutex/condition waits, positive Eio clock sleeps, TLS
  progress, HTTP client/server waits, stream file/mailbox waits, and the owner
  wait for a system-thread blocking job. Immediate I/O or an uncontended lock is
  not made a checkpoint by Eta.
- JS host services are checkpoints while their `Eta_jsoo.Private.await` or
  `Effect.async` continuation is pending (for example HTTP `fetch`); their host
  cancellation hook runs only when provided.
- `Effect.pure`, `fail`, ordinary `map`/`bind`, and a purely synchronous
  `Effect.sync` callback are not checkpoints. A sync callback that directly
  invokes a blocking backend operation inherits that operation's checkpoint.
- Eta finalizers and `Effect.finally` cleanup run under contract protection.
  Their internal waits deliberately do not restore parent cancellation.

The durable user-facing version is in `docs/api-dx.md`.

## V-DX-E15-004 — native restore obstruction

The simple construction is disproved: `protect (fun () -> cancel_sub body)`
cannot restore the context outside `protect`.

A synthetic relay also fails the exact model on the current contract:

1. Eta can fork a watcher only into a `Runtime_contract.scope`. It cannot
   subscribe to or fork into the exact current `cancel_context`.
2. Eta has real nested synthetic contexts in `Effect.async`, blocking work,
   supervisor children, and signal timers.
3. Put a fiber in such a context `C`, enter `uninterruptible` (Eio protected
   context `P`), then enter a proposed interruptible sub-context `S` below `P`.
4. Explicitly cancel `C` while its owning scope remains live. Cancellation stops
   at `P`; a scope-level relay is not cancelled; `S` remains blocked.

This is a lost wakeup: cancellation exists in the exact parent being restored,
but no current contract operation can deliver it to the blocked point. Entry and
exit snapshots cannot fix cancellation that arrives after the snapshot while a
network accept or other service await is parked. Polling would not cancel the
backend operation and is not an acceptable cancellation model.

Eliminating the construction requires at least one of:

- an Eio primitive that temporarily restores/moves a fiber to the context
  outside `Cancel.protect`;
- an observer/child-attachment API for an arbitrary Eio cancellation context;
- a redesign of Eta's cancellation handles and every synthetic `cancel_sub` so
  cancellation can notify mask relays.

Eio's public and `Eio.Private` interfaces expose context inspection and
cancellation functions for a currently suspended fiber, but no operation that
attaches a new descendant/watcher to an arbitrary existing context or moves the
running fiber back to it. The required alternatives therefore widen or redesign
the cancellation surface rather than implement one small mask operation.

## Phase 0 gate

**Closed: does not admit Phase 1 implementation.** jsoo has a local depth
mapping; native Eio has no honest restore on the existing substrate, and the
relay construction has an uneliminated lost wakeup for exact-parent synthetic
cancellation. The kill criteria require stopping here.

## Follow-up 1 — gate correction and verified construction

The preceding Phase 0 probe results remain true, but the gate conclusion was
wrong. They reject `protect` plus descendant `sub` and the scope-relay fallback;
they do not reject Eio's hidden same-fiber switch operation.

Independent review found and the orchestrator reproduced Eio's hidden core
switch `run_in` operation. A mask-entry switch created before `Cancel.protect`
retains the exact current parent cancellation path:

```text
C  exact current context
└─ R  mask-entry switch
   └─ P  protected context
```

Moving the current fiber from `P` into `R` makes cancellation propagate from
`C` and wake a blocked operation without a fork. The independent output was:

```text
restore-during-block: DELIVERED
restore-pending-entry: RAISED
```

The resumed implementation also checks the restored context after a successful
callback, closing the cancel-between-tail-and-exit edge. Its real loopback accept
victim produces:

```text
accept-loop-victim: INTERRUPTED
accept-loop-victim: PASS
```

Corrections to V-DX-E15-004:

- “no restore primitive” was false: the hidden switch implementation provides
  the needed current-fiber move;
- “every synthetic sub-context must be redesigned” was false: creating `R`
  inside the exact current synthetic context preserves its cancellation path;
- “private-context move unavailable” was false for Eio's hidden implementation.

The scope-relay lost wakeup remains a valid rejection of that relay. It is not a
lost wakeup in the `run_in` construction. The Phase 0 gate is therefore
**REOPENED** and admits the Phase 1/2 implementation recorded in `report.md`.
