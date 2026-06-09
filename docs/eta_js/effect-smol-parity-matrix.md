# Eta JS / Effect-Smol Parity Matrix

> Last updated: 2026-06-08
>
> Effect-smol is behavioral prior art, not a dependency. Eta does not copy its
> environment/layer/application-framework surface unless the app-boundary policy
> explicitly changes.

## Legend

| Status | Meaning |
|--------|---------|
| `implemented` | Present with tests |
| `implemented-needs-tests` | Present, tests incomplete |
| `planned` | Slated for this series |
| `deferred` | Future work, not this series |
| `non-goal` | Intentionally out of scope |

---

## Core Effect Construction and Composition

| Area | Effect-smol reference | Eta native reference | Eta JS status | Target | Tests |
|------|----------------------|----------------------|---------------|--------|-------|
| `pure` | `Effect.ts` | `Effect.pure` | `implemented` | stable | `test/js/test_pure.ml` |
| `fail` | `Effect.ts` | `Effect.fail` | `implemented` | stable | `test/js/test_pure.ml` |
| `sync` | `Effect.ts` | `Effect.sync` | `implemented` | stable | `test/js/test_runtime.ml` |
| `map` | `Effect.ts` | `Effect.map` | `implemented` | stable | `test/js/test_runtime.ml` |
| `bind` | `Effect.ts` | `Effect.bind` | `implemented` | stable | `test/js/test_runtime.ml` |
| `tap` | `Effect.ts` | `Effect.tap` | `implemented` | stable | `test/js/test_runtime.ml` |
| `zip` | `Effect.ts` | `Effect.zip` (via `par`) | `implemented` | stable | `test/js/test_runtime.ml` |
| `match` / `matchEffect` | `Effect.ts` | `Effect.match_` / `match_effect` | `implemented` | Phase 3 | `test/js/test_cause_effect.ml` |
| `catch` | `Effect.ts` | `Effect.catch` | `implemented` | stable | `test/js/test_runtime.ml` |
| `catchCause` | `Effect.ts` | `Effect.catch_cause` | `implemented` | Phase 3 | `test/js/test_cause_effect.ml` |
| `tapCause` | `Effect.ts` | `Effect.tap_cause` | `implemented` | Phase 3 | `test/js/test_cause_effect.ml` |
| `sandbox` / `unsandbox` | `Effect.ts` | `Effect.sandbox` / `unsandbox` | `implemented` | Phase 3 | `test/js/test_cause_effect.ml` |
| `die` | `Effect.ts` | `Effect.die` | `implemented` | Phase 3 | `test/js/test_cause_effect.ml` |
| `failCause` | `Effect.ts` | `Effect.fail_cause` | `implemented` | Phase 3 | `test/js/test_cause_effect.ml` |
| `yieldNow` | `Effect.ts` | `Effect.yield_now` | `implemented` | stable | `test/js/test_runtime.ml` |
| `check` | `Effect.ts` | `Effect.check` | `implemented` | stable | `test/js/test_runtime.ml` |
| `delay` | `Effect.ts` | `Effect.delay` | `implemented` | Phase 1 | `test/js/test_clock.ml` |
| `timeout` / `timeoutTo` | `Effect.ts` | `Effect.timeout` / `timeout_as` | `implemented` | stable | `test/js/test_runtime.ml` |
| `race` | `Effect.ts` | `Effect.race` | `implemented` | stable | `test/js/test_runtime.ml` |
| `all` | `Effect.ts` | `Effect.all` | `implemented` | stable | `test/js/test_runtime.ml` |
| `allSettled` | `Effect.ts` | `Effect.all_settled` | `implemented` | stable | `test/js/test_runtime.ml` |
| `forEach` / `forEachPar` | `Effect.ts` | `Effect.for_each_par` | `implemented` | stable | `test/js/test_runtime.ml` |
| `forEachParBounded` | `Effect.ts` | `Effect.for_each_par_bounded` | `implemented` | stable | `test/js/test_runtime.ml` |
| `retry` | `Effect.ts` | `Effect.retry` | `implemented` | stable | `test/js/test_runtime.ml` |
| `repeat` | `Effect.ts` | `Effect.repeat` | `implemented` | stable | `test/js/test_runtime.ml` |
| `acquireUseRelease` | `Effect.ts` | `Effect.acquire_use_release` | `implemented` | stable | `test/js/test_runtime.ml` |
| `finally` | `Effect.ts` | `Effect.finally` | `implemented` | stable | `test/js/test_runtime.ml` |
| `uninterruptible` | `Effect.ts` | `Effect.uninterruptible` | `implemented` | Phase 3 | `test/js/test_uninterruptible.ml` |
| `uninterruptibleMask` | `Effect.ts` | `Effect.uninterruptible_mask` | `deferred` | future | `test/js/test_uninterruptible.ml` |

## Fiber Handles

| Area | Effect-smol reference | Eta native reference | Eta JS status | Target | Tests |
|------|----------------------|----------------------|---------------|--------|-------|
| `fork` | `Fiber.ts` | `Par.fork` / `Runtime.fork` | `implemented` | Phase 2 | `test/js/test_fiber.ml` |
| `forkScoped` | `Fiber.ts` | `Scope.fork` | `implemented` | Phase 2 | `test/js/test_fiber.ml` |
| `forkDaemon` | `Fiber.ts` | `Effect.daemon` | `implemented` | Phase 2 | `test/js/test_fiber.ml` |
| `await` | `Fiber.ts` | `Fiber.await` | `implemented` | Phase 2 | `test/js/test_fiber.ml` |
| `join` | `Fiber.ts` | `Fiber.join` | `implemented` | Phase 2 | `test/js/test_fiber.ml` |
| `interrupt` | `Fiber.ts` | `Fiber.interrupt` | `implemented` | Phase 2 | `test/js/test_fiber.ml` |
| `poll` | `Fiber.ts` | `Fiber.poll` | `implemented` | Phase 2 | `test/js/test_fiber.ml` |
| `id` | `Fiber.ts` | `Fiber.id` | `implemented` | Phase 2 | `test/js/test_fiber.ml` |
| `Supervisor.scoped` | `Effect.ts` | `Supervisor.scoped` | `implemented` | stable | `test/js/test_supervisor.ml` |
| `Supervisor.start/await/cancel` | `Effect.ts` | `Supervisor.Scope.start/await/cancel` | `implemented` | stable | `test/js/test_supervisor.ml` |

## Deferred / Latch

| Area | Effect-smol reference | Eta native reference | Eta JS status | Target | Tests |
|------|----------------------|----------------------|---------------|--------|-------|
| `Deferred` | `Deferred.ts` | `Deferred` (native Eta) | `implemented` | Phase 4 | `test/js/test_deferred.ml` |
| `Deferred.make` | `Deferred.ts` | `Deferred.make` | `implemented` | Phase 4 | `test/js/test_deferred.ml` |
| `Deferred.await` | `Deferred.ts` | `Deferred.await` | `implemented` | Phase 4 | `test/js/test_deferred.ml` |
| `Deferred.succeed/fail/done` | `Deferred.ts` | `Deferred.succeed/fail/done` | `implemented` | Phase 4 | `test/js/test_deferred.ml` |
| `Latch` | internal | internal | `implemented` | Phase 4 | `test/js/test_latch.ml` |

## Ref and Synchronized Ref

| Area | Effect-smol reference | Eta native reference | Eta JS status | Target | Tests |
|------|----------------------|----------------------|---------------|--------|-------|
| `Ref.make/get/set/update` | `Ref.ts` | `Ref` | `implemented` | Phase 4 | `test/js/test_ref.ml` |
| `Ref.modify` | `Ref.ts` | `Ref.modify` | `implemented` | Phase 4 | `test/js/test_ref.ml` |
| `SynchronizedRef` | `Ref.ts` | `SynchronizedRef` | `implemented` | Phase 4 | `test/js/test_synchronized_ref.ml` |

## Clock

| Area | Effect-smol reference | Eta native reference | Eta JS status | Target | Tests |
|------|----------------------|----------------------|---------------|--------|-------|
| `Clock.currentTimeMillis` | `Clock.ts` | `Duration.now` | `implemented` | Phase 1 | `test/js/test_clock.ml` |
| `Clock.sleep` | `Clock.ts` | `Effect.delay` | `implemented` | Phase 1 | `test/js/test_clock.ml` |
| Virtual clock for tests | `Clock.ts` | `Test_clock` | `implemented` | Phase 1 | `test/js/test_clock.ml` |
| Runtime clock injection | `Clock.ts` | `Runtime.create ~clock` | `implemented` | Phase 1 | `test/js/test_clock.ml` |

## Queue / Channel / Semaphore / PubSub / Pool

| Area | Effect-smol reference | Eta native reference | Eta JS status | Target | Tests |
|------|----------------------|----------------------|---------------|--------|-------|
| `Queue` | `Queue.ts` | `Queue` | `implemented` | stable | `test/js/test_queue.ml` |
| `Channel` | `Channel.ts` | `Channel` | `implemented` | stable | `test/js/test_channel.ml` |
| `Semaphore` | `Semaphore.ts` | `Semaphore` | `implemented` | stable | `test/js/test_semaphore.ml` |
| `PubSub` | `PubSub.ts` | `Pubsub` | `implemented` | stable | `test/js/test_pubsub.ml` |
| `Pool` | `Pool.ts` | `Pool` | `implemented` | stable | `test/js/test_pool.ml` |
| Stress/property tests | `Queue.ts` etc. | native stress tests | `planned` | Phase 5 | `test/js/test_stress.ml` |

## Stream

| Area | Effect-smol reference | Eta native reference | Eta JS status | Target | Tests |
|------|----------------------|----------------------|---------------|--------|-------|
| `Stream` package shell | `Stream.ts` | `eta_stream` | `implemented` | Phase 6 | `test/js_stream/` |
| Pure constructors / sinks | `Stream.ts` | `Stream` / `Sink` | `implemented` | Phase 6 | `test/js_stream/run_js_stream_tests.ml` |
| Mailbox / queue sources | `Stream.ts` | `Stream.from_queue` | `planned` | Phase 6 | `test/js_stream/run_js_stream_tests.ml` |
| `merge` | `Stream.ts` | `Stream.merge` | `planned` | Phase 6 | `test/js_stream/run_js_stream_tests.ml` |
| `flatMapPar` | `Stream.ts` | `Stream.flat_map_par` | `planned` | Phase 6 | `test/js_stream/run_js_stream_tests.ml` |

## Observability

| Area | Effect-smol reference | Eta native reference | Eta JS status | Target | Tests |
|------|----------------------|----------------------|---------------|--------|-------|
| `Effect.named` | `Effect.ts` | `Effect.named` | `planned` | Phase 7 | `test/js/test_observability.ml` |
| `Effect.withSpan` | `Effect.ts` | `Effect.with_span` | `planned` | Phase 7 | `test/js/test_observability.ml` |
| `Effect.annotate` | `Effect.ts` | `Effect.annotate` / `annotate_all` | `planned` | Phase 7 | `test/js/test_observability.ml` |
| `Effect.log` / `logDebug` etc. | `Effect.ts` | `Effect.log` / `log_level` | `planned` | Phase 7 | `test/js/test_observability.ml` |
| Tracer / logger / meter | `Tracer.ts` | `Capabilities` | `implemented` | stable | `test/js/test_runtime.ml` |
| Daemon failure diagnostics | internal | internal | `planned` | Phase 7 | `test/js/test_runtime.ml` |

## Promise Bridge

| Area | Effect-smol reference | Eta native reference | Eta JS status | Target | Tests |
|------|----------------------|----------------------|---------------|--------|-------|
| `Promise.awaitPromise` | `Effect.ts` | `Promise.await_promise` | `implemented` | stable | `test/js/test_promise.ml` |
| `Promise.awaitAbortable` | `Effect.ts` | `Promise.await_abortable` | `implemented` | stable | `test/js/test_promise.ml` |

## Runtime

| Area | Effect-smol reference | Eta native reference | Eta JS status | Target | Tests |
|------|----------------------|----------------------|---------------|--------|-------|
| `runPromise` | `Effect.ts` | `Runtime.run_promise` | `implemented` | stable | `test/js/test_runtime.ml` |
| `runPromiseExit` | `Effect.ts` | `Runtime.run_promise` | `implemented` | stable | `test/js/test_runtime.ml` |
| `runSync` | `Effect.ts` | `Runtime.run_now` | `implemented` | stable | `test/js/test_runtime.ml` |
| `runFork` | `Effect.ts` | `Runtime.run_fork` | `implemented` | Phase 2 | `test/js/test_fiber.ml` |
| `Runtime.drainPromise` | internal | `Runtime.drain_promise` | `implemented` | stable | `test/js/test_runtime.ml` |
| Node `run_main` | internal | `Node_main.run_main` | `implemented` | Phase 8 | `test/js_node/run_js_node_tests.ml` |

## Browser / Platform

| Area | Effect-smol reference | Eta native reference | Eta JS status | Target | Tests |
|------|----------------------|----------------------|---------------|--------|-------|
| Browser smoke tests | internal | internal | `planned` | Phase 8 | `test/js_browser/` |
| Node `run_main` | internal | `Node_main.run_main` | `implemented` | Phase 8 | `test/js_node/` |

## Explicit Non-Goals

- **Effect-smol `Layer` / `Context` / application dependency-injection:** Eta's app-boundary policy keeps application state in ordinary OCaml values. No Layer port unless policy changes.
- **Schema, SQL, AI, FileSystem, Terminal, Node platform packages:** Out of scope for this series.
- **Eio, native blocking, Cstruct, file-path, or native stream dependencies in `eta_js`:** Package boundary violation.
- **npm package publishing:** Needs separate packaging plan after browser/Node smoke tests pass.
