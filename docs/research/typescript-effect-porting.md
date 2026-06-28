I dug through .reference/effect-smol/packages/effect/test/* against Eta’s
current   public core surface in lib/eta. The best ports are not line-for-line
API ports; they are invariant ports. Don't trust this list blindly, you role is not only to port, but confirm what should be ported.

  Highest-Value Ports

  1. Effect finalization / resource safety
     Source: .reference/effect-smol/packages/effect/test/Effect.test.ts, especially
     acquireRelease, finalization, timeout, interruption.
     Applicable to Eta:
      - Effect.acquire_release releases on success.
      - releases on typed failure.
      - releases on defect from sync.
      - releases on cancellation / timeout.
      - finalizer failure after success becomes the run failure.
      - finalizer failure after primary failure is reported as Cause.Suppressed.
      - Effect.finally has the same success/failure/suppression behavior.

     Eta already has the right concepts: Cause.Suppressed, timeout_as,
     acquire_use_release, scoped, uninterruptible. These tests should be first because
     they protect the hardest runtime contract.
  2. Typed error vs defect vs interruption separation
     Source: .reference/effect-smol/packages/effect/test/Cause.test.ts and Effect.test.ts
     error handling sections.
     Applicable to Eta:
      - Effect.fail e becomes Exit.Error (Cause.Fail e).
      - exception in Effect.sync becomes Cause.Die.
      - Exit.to_result returns Some (Error e) only for single typed failures.
      - Exit.to_result returns None for Die, Interrupt, Sequential, Concurrent,
        Suppressed.
      - Effect.map_error maps all Cause.Fail values inside nested cause trees while
        preserving dies and interrupts.
      - Effect.catch catches typed failures only, not defects.
      - Effect.tap_error preserves the original typed failure, and observer defects
        become suppressed finalizer causes.
  3. Concurrent combinators
     Source: .reference/effect-smol/packages/effect/test/Effect.test.ts: forEach, all,
     raceAll, timeout/interruption sections.
     Applicable to Eta:
      - Effect.all preserves input order.
      - Effect.all [] returns Ok [].
      - Effect.all is fail-fast and cancels siblings.
      - Effect.all_settled preserves input order and returns every child outcome.
      - Effect.for_each_par preserves input order.
      - Effect.for_each_par_bounded ~max never exceeds max concurrent children.
      - Effect.for_each_par_bounded ~max:0 raises Invalid_argument.
      - Effect.race returns the first success and cancels losers.
      - Effect.race propagates first observed failure when the failing child wins.
  4. Schedule semantics
     Source: .reference/effect-smol/packages/effect/test/Schedule.test.ts, mainly spaced,
     fixed, jittered.
     Applicable to Eta:
      - Schedule.recurs n yields exactly n delays then terminates.
      - spaced d yields constant d.
      - fixed d yields constant d in Eta’s simpler driver model.
      - exponential ~factor base produces expected geometric delays.
      - linear ~initial ~step increments predictably.
      - both, either, and and_then terminate according to their composition rules.
      - jittered ~min ~max keeps delay inside the multiplier bounds.
      - seeded random makes jitter deterministic.
  5. Retry / repeat
     Source: .reference/effect-smol/packages/effect/test/Effect.test.ts: repeat, retry.
     Applicable to Eta:
      - retry does nothing on initial success.
      - retry (recurs n) attempts initial run plus n retries.
      - retry stops when the predicate rejects the typed error.
      - retry does not catch defects.
      - repeat (recurs n) performs the expected number of body executions.
      - scheduled retry/repeat sleeps according to schedule delays.
      - timeout during retry/repeat interrupts the loop and returns timeout failure.
  6. Pool lifecycle
     Source: .reference/effect-smol/packages/effect/test/Pool.test.ts.
     Applicable to Eta’s Eta.Pool, with adjusted names:
      - max pool size is respected under concurrent checkout.
      - released resources are reused.
      - body success releases resource.
      - body typed failure releases resource.
      - body defect releases resource.
      - waiting checkout is cancellation-safe and does not consume capacity.
      - shutdown wakes pending waiters with Pool_shutdown.
      - shutdown closes idle resources.
      - shutdown waits for checked-out resources until deadline.
      - health check rejection does not leak capacity.
      - acquire failure does not count as an active resource.
  7. Semaphore cancellation and permit accounting
     Source: .reference/effect-smol/packages/effect/test/Semaphore.test.ts.
     Applicable to Eta:
      - make ~permits:0 raises.
      - try_acquire succeeds/fails atomically.
      - acquire blocks until enough permits exist.
      - with_permits releases on success.
      - with_permits releases on typed failure.
      - with_permits releases on defect.
      - cancelled waiters do not leak permits.
      - FIFO wake behavior for compatible waiters.
      - requesting more than capacity raises in Eta, rather than “returns never” as
        Effect does.
  8. PubSub delivery and lifecycle
     Source: .reference/effect-smol/packages/effect/test/PubSub.test.ts.
     Applicable to Eta:
      - one publisher / one subscriber preserves order.
      - one publisher / many subscribers delivers each message to each current
        subscriber.
      - many publishers / many subscribers preserve per-publisher message sets.
      - publishing with no subscribers does not retain messages.
      - late subscribers do not receive old messages.
      - Drop_new drops new messages when full and reports dropped count.
      - Backpressure blocks publisher when hub is full.
      - cancelled publisher waiting on backpressure does not partially publish.
      - closing wakes suspended subscribers.
      - close with error drains buffered messages, then fails receives with the typed
        close error.
      - escaped subscription fails after subscribe scope exits.
  9. Channel bounded queue invariants
     Source: partly .reference/effect-smol/packages/effect/test/Channel.test.ts, but
     Eta’s Channel is a bounded same-domain primitive, not Effect’s stream-channel
     abstraction.
     Applicable invariants:
      - FIFO send/recv.
      - try_recv on empty returns Empty.
      - try_send on full returns Full.
      - send blocks when full and resumes when receiver drains.
      - recv blocks when empty and resumes when sender sends.
      - close wakes blocked senders and receivers.
      - buffered values remain drainable after close.
      - close-with-error preserves buffered values, then fails with typed error.
      - cancelled sender waiting on full channel is removed and does not later enqueue.
  10. Duration arithmetic
     Source: .reference/effect-smol/packages/effect/test/Duration.test.ts.
     Applicable subset:

  - constructors convert to expected milliseconds.
  - add, subtract, times, divide, min, max, clamp, between, compare.
  - divide by zero returns None.
  - zero detection.

  Not applicable: string parsing, nanoseconds, JSON, inspect, HR time, JS-specific
  negative/infinity behavior unless Eta intentionally supports it.

  Already Partially Covered
  Eta already has some nearby tests:

  - test/par/test_par.ml covers Eta.Par fork-join correctness, exceptions, deep
    recursion, sorting, reduction.
  - test/stream/test_eta_stream.ml covers some stream cancellation, queue close, bounded
    concurrency.
  - test/test/test_eta_test.ml covers test helpers, seeded jitter, test clock, logger/
    tracer helpers.

  But Eta seems thin on direct core runtime tests for Effect, Cause, Exit, Schedule,
  Pool, Channel, PubSub, and Semaphore. Those are where effect-smol gives the most
  leverage.

  Not Worth Porting
  Skip or defer these because Eta does not have the same abstraction or the tests are
  TypeScript/platform-specific:

  - Context, Layer, Service, provide, environment tests.
  - gen, pipeability, TypeId, branding, structural JS equality.
  - Option, Result, Array, Chunk, HashSet, Record, Tuple, Predicate, etc. unless Eta adds
    matching utility modules.
  - Deferred, Fiber, FiberMap, FiberHandle, ScopedRef, RcRef unless Eta exposes
    equivalent public APIs.
  - Transactional refs/queues/semaphores: Tx*.
  - Schema, JSON schema, RPC, cluster, browser/node platform suites.
  - Effect-smol Channel tests that target stream transducers rather than Eta’s bounded
    Channel.
  - Partitioned semaphore tests; Eta’s semaphore is intentionally simpler.
