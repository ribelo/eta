# Blocking admission prior art in Effect Smol and ZIO

Date: 2026-08-04

## Question

Do Effect Smol or ZIO already provide the blocking admission operation selected
for Eta?

The selected Eta contract has these parts:

- `try_run` and `try_run_result` select fail-fast admission at the operation.
- Admission requires an immediately available worker and never uses queue
  capacity.
- Saturation does not run the callback.
- Shutdown before callback start does not run the callback.
- The result is `Completed value` or `Not_run admission_failure`.
- `admission_failure` distinguishes `Saturated` from `Shutting_down`.
- Callback failures remain in the existing typed error channel.
- Cancellation before the worker claim prevents the callback.
- Cancellation after the worker claim obeys the blocking pool's shutdown policy.

## Source revisions

- Effect Smol: commit
  [`717d1c8b160d4de631b6b7938abcad9e3472c3d7`](https://github.com/Effect-TS/effect-smol/tree/717d1c8b160d4de631b6b7938abcad9e3472c3d7)
- ZIO: commit
  [`770b408eb0157d2f328d8fb918ed0fc289b5933a`](https://github.com/zio/zio/tree/770b408eb0157d2f328d8fb918ed0fc289b5933a)

## Result

Neither project provides the complete Eta contract.

Both projects provide a close semaphore operation. The semaphore operation
validates the operation-level `try_run` direction and the separate outcome
direction. It does not own a blocking worker pool, a bounded worker queue, pool
shutdown, or detached native work.

ZIO also exposes low-level executor admission as a Boolean. This operation does
not preserve an effect result. It does not distinguish saturation from shutdown.
ZIO converts rejected scheduling to an exception in its normal fiber runtime.

## Effect Smol

### Closest operation

`Semaphore.withPermitsIfAvailable` runs an effect only when permits are
immediately available. It returns `Option.some(value)` after execution. It
returns `Option.none` without execution when admission fails.

The effect keeps its existing error type:

```ts
withPermitsIfAvailable(
  permits: number
): <A, E, R>(self: Effect<A, E, R>) => Effect<Option<A>, E, R>
```

The implementation performs the availability check and permit acquisition in
one uninterruptible section. It releases the permit when the effect exits.

Sources:

- [`Semaphore.ts`, operation contract, lines 99-118](https://github.com/Effect-TS/effect-smol/blob/717d1c8b160d4de631b6b7938abcad9e3472c3d7/packages/effect/src/Semaphore.ts#L99-L118)
- [`Semaphore.ts`, implementation, lines 283-292](https://github.com/Effect-TS/effect-smol/blob/717d1c8b160d4de631b6b7938abcad9e3472c3d7/packages/effect/src/Semaphore.ts#L283-L292)
- [`PartitionedSemaphore.test.ts`, no-run case, lines 55-73](https://github.com/Effect-TS/effect-smol/blob/717d1c8b160d4de631b6b7938abcad9e3472c3d7/packages/effect/test/PartitionedSemaphore.test.ts#L55-L73)

This shape matches three selected Eta properties:

1. The operation selects fail-fast behavior.
2. Failed admission does not run the guarded effect.
3. Guarded-effect failures remain unchanged in the effect error channel.

### Missing properties

Effect Smol has no native blocking executor with Eta's pool contract. Its
semaphore has no shutdown state. `Option.none` therefore has only one meaning.
It cannot distinguish `Saturated` from `Shutting_down`.

The semaphore releases a permit when the guarded effect exits. It does not own a
separate physical callback that can remain active after the caller detaches.
Therefore, it does not supply Eta's detached-work slot fence.

Effect Smol queues provide another partial precedent. `Queue.offer` returns a
Boolean, and `Queue.offerUnsafe` returns `false` for a full non-sliding queue or
a completed queue. This result combines capacity failure and terminal state.
Queue shutdown also resumes suspended offers with negative results.

Sources:

- [`Queue.ts`, `offer`, lines 601-655](https://github.com/Effect-TS/effect-smol/blob/717d1c8b160d4de631b6b7938abcad9e3472c3d7/packages/effect/src/Queue.ts#L601-L655)
- [`Queue.ts`, `offerUnsafe`, lines 658-707](https://github.com/Effect-TS/effect-smol/blob/717d1c8b160d4de631b6b7938abcad9e3472c3d7/packages/effect/src/Queue.ts#L658-L707)
- [`Queue.ts`, shutdown, lines 1114-1133](https://github.com/Effect-TS/effect-smol/blob/717d1c8b160d4de631b6b7938abcad9e3472c3d7/packages/effect/src/Queue.ts#L1114-L1133)

## ZIO

### Closest high-level operation

`Semaphore.tryWithPermit` and `Semaphore.tryWithPermits` have the same high-level
shape as the Effect Smol operation:

```scala
def tryWithPermit[R, E, A](zio: ZIO[R, E, A]): ZIO[R, E, Option[A]]
```

The implementation reserves permits atomically. It runs the effect only after a
successful reservation. It releases the reservation after success, failure, or
interruption.

Sources:

- [`Semaphore.scala`, public contract, lines 48-60](https://github.com/zio/zio/blob/770b408eb0157d2f328d8fb918ed0fc289b5933a/core/shared/src/main/scala/zio/Semaphore.scala#L48-L60)
- [`Semaphore.scala`, implementation, lines 128-149](https://github.com/zio/zio/blob/770b408eb0157d2f328d8fb918ed0fc289b5933a/core/shared/src/main/scala/zio/Semaphore.scala#L128-L149)
- [`TSemaphore.scala`, transactional form, lines 112-146](https://github.com/zio/zio/blob/770b408eb0157d2f328d8fb918ed0fc289b5933a/core/shared/src/main/scala/zio/stm/TSemaphore.scala#L112-L146)

This is strong prior art for Eta's operation-level fail-fast method. It is not a
blocking worker admission method. It has no pool shutdown result and no detached
callback accounting.

### Executor admission

ZIO's low-level `Executor.submit` returns `Boolean`. A `ThreadPoolExecutor`
adapter catches `RejectedExecutionException` and returns `false`.

The normal fiber runtime does not return this Boolean to application code. It
uses `submitOrThrow` and `submitAndYieldOrThrow`. These methods convert rejection
back to `RejectedExecutionException`.

Sources:

- [`Executor.scala`, `submit`, lines 25-40](https://github.com/zio/zio/blob/770b408eb0157d2f328d8fb918ed0fc289b5933a/core/shared/src/main/scala/zio/Executor.scala#L25-L40)
- [`Executor.scala`, throwing wrappers, lines 61-79](https://github.com/zio/zio/blob/770b408eb0157d2f328d8fb918ed0fc289b5933a/core/shared/src/main/scala/zio/Executor.scala#L61-L79)
- [`DefaultExecutors.scala`, adapter, lines 31-65](https://github.com/zio/zio/blob/770b408eb0157d2f328d8fb918ed0fc289b5933a/core/jvm-native/src/main/scala/zio/internal/DefaultExecutors.scala#L31-L65)
- [`FiberRuntime.scala`, normal submission, lines 300-308](https://github.com/zio/zio/blob/770b408eb0157d2f328d8fb918ed0fc289b5933a/core/shared/src/main/scala/zio/internal/FiberRuntime.scala#L300-L308)

This executor behavior resembles Eta's current defect. The substrate detects
rejection, but the high-level effect does not expose a structured admission
result.

### Blocking executor

`ZIO.attemptBlocking` shifts work to the blocking executor. The default JVM
blocking executor uses a `SynchronousQueue` and `Int.MaxValue` maximum threads.
It therefore grows threads instead of providing bounded saturation admission.

Sources:

- [`ZIOCompanionVersionSpecific.scala`, `attemptBlocking`, lines 104-117](https://github.com/zio/zio/blob/770b408eb0157d2f328d8fb918ed0fc289b5933a/core/shared/src/main/scala-2/zio/ZIOCompanionVersionSpecific.scala#L104-L117)
- [`ZIO.scala`, blocking executor selection, lines 2882-2893](https://github.com/zio/zio/blob/770b408eb0157d2f328d8fb918ed0fc289b5933a/core/shared/src/main/scala/zio/ZIO.scala#L2882-L2893)
- [`Blocking.scala`, default blocking executor, lines 21-44](https://github.com/zio/zio/blob/770b408eb0157d2f328d8fb918ed0fc289b5933a/core/jvm-native/src/main/scala/zio/internal/Blocking.scala#L21-L44)

ZIO has interruptible and cancelable blocking helpers. These helpers attempt to
stop native work. They do not model Eta's policy where the caller detaches while
the physical callback retains its worker slot.

Source:

- [`ZIOPlatformSpecific.scala`, interruptible blocking, lines 54-118](https://github.com/zio/zio/blob/770b408eb0157d2f328d8fb918ed0fc289b5933a/core/jvm-native/src/main/scala/zio/ZIOPlatformSpecific.scala#L54-L118)

## Consequences for Eta

The approved Eta direction is not an invention without precedent. Both reference
libraries put fail-fast behavior on the operation. Both return non-admission on
the success side and preserve the guarded effect's error channel.

Eta needs a dedicated outcome instead of `Option` because Eta has two required
non-run reasons. Eta must distinguish capacity saturation from pool shutdown.

Eta also needs a blocking-specific implementation. A semaphore wrapper cannot
hold admission after caller detachment unless it owns physical callback
completion. Eta's blocking pool already owns that completion signal.

The comparison supports the selected direction:

```ocaml
type admission_failure = Saturated | Shutting_down
type 'a try_run_outcome = Completed of 'a | Not_run of admission_failure

val try_run : ... -> ('a try_run_outcome, 'err) Eta.Effect.t
val try_run_result : ... -> ('a try_run_outcome, 'err) Eta.Effect.t
```

The comparison does not require Eta to copy either implementation. Eta's bounded
worker queue, shutdown policies, callback-start race, metrics, and detached-work
accounting remain Eta-owned behavior.
