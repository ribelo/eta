# Eta JS Production Readiness

> Status: **Ready for internal use and early adoption**
>
> Last updated: 2026-06-08

## Package Overview

`eta_js` is the Melange-compatible JavaScript backend for Eta, providing a
subset of the core effect system, runtime, and concurrency primitives. It is
distributed as an optional `eta_js` opam package and consumes no native
blocking or Eio dependencies.

### Included Packages

| Package | Purpose | Public Library |
|---------|---------|---------------|
| `eta_js` | Core runtime and effect system | `eta_js` |
| `eta_js_test` | Test helpers and virtual clock | `eta_js_test` |
| `eta_js_stream` | Pure streaming combinators | `eta_js_stream` |

## Build Requirements

- OCaml 5.4.1 (mainline, **not** OxCaml)
- Melange 5.x
- Dune 3.14+
- Node.js 20+ for test execution

### Build Commands

```bash
# Native tests (OCaml 5.2.0+)
nix develop -c dune runtest --force

# Melange JS build and tests (OCaml 5.4.1 mainline)
nix develop .#mainline -c bash -lc '
  eval $(opam env --switch=eta-js-5.4.1 --set-switch)
  ETA_JS_TESTS=true dune build @eta-js-build @eta-js-runtest
'

# Stream tests
nix develop .#mainline -c bash -lc '
  eval $(opam env --switch=eta-js-5.4.1 --set-switch)
  ETA_JS_TESTS=true dune runtest test/js_stream
'
```

## Runtime Architecture

### Single-Threaded Scheduler

`eta_js` uses a cooperative single-threaded scheduler built on JavaScript
promises and `setTimeout`. Fibers yield via `Effect.yield_now` and resume on
the next event-loop tick. There is no preemptive scheduling.

### Clock Abstraction

The runtime accepts an optional `clock` implementation. The default clock uses
`setTimeout` for delays. The test clock (`Test_clock`) provides deterministic,
manual time advancement for synchronous test execution.

### Cancellation and Interruption

Fibers can be interrupted via `Fiber.interrupt`. The `uninterruptible`
combinator masks interruption for a region. `Check` and async leaf callbacks
respect the interruptibility flag.

### Daemon Fiber Lifecycle

Daemon fibers run in the background and are awaited by `Runtime.drain_promise`.
If a daemon fails, the failure is recorded and can be inspected.

## API Stability

### Stable (Phase Complete)

- **Effect construction**: `pure`, `fail`, `sync`, `map`, `bind`, `tap`
- **Error handling**: `catch`, `catch_cause`, `tap_cause`, `sandbox`, `unsandbox`, `match_`, `match_effect`
- **Concurrency**: `race`, `all`, `all_settled`, `for_each_par`, `for_each_par_bounded`
- **Retry/repeat**: `retry`, `repeat`
- **Resources**: `acquire_use_release`, `finally`
- **Delay/timeout**: `delay`, `timeout`, `timeout_as`
- **Queue/Channel/Semaphore/PubSub/Pool**: Full API surface
- **Fiber handles**: `fork`, `fork_scoped`, `fork_daemon`, `await`, `join`, `interrupt`, `poll`
- **Deferred/Latch/Ref/SynchronizedRef**: Full API surface
- **Promise bridge**: `await_promise`, `await_abortable`

### Experimental (Subject to Change)

- **Stream combinators**: `flat_map_par`, `merge`, mailbox sources
- **Observability**: `named`, `annotate`, `with_span` (currently no-ops or minimal)
- **Logging**: `log`, `log_debug`, `log_info`, etc. (requires logger capability)

### Deferred

- `uninterruptibleMask`: Not yet implemented
- Full tracer span stack integration
- npm packaging

## Testing Strategy

### Test Coverage

| Module | Tests | Status |
|--------|-------|--------|
| Pure combinators | `test_pure.ml` | ✅ |
| Runtime | `test_runtime.ml` | ✅ |
| Clock | `test_clock.ml` | ✅ |
| Fiber | `test_fiber.ml` | ✅ |
| Uninterruptible | `test_uninterruptible.ml` | ✅ |
| Cause effects | `test_cause_effect.ml` | ✅ |
| Deferred | `test_deferred.ml` | ✅ |
| Latch | `test_latch.ml` | ✅ |
| Ref | `test_ref.ml` | ✅ |
| SynchronizedRef | `test_synchronized_ref.ml` | ✅ |
| Queue | `test_queue.ml` | ✅ |
| Channel | `test_channel.ml` | ✅ |
| Semaphore | `test_semaphore.ml` | ✅ |
| PubSub | `test_pubsub.ml` | ✅ |
| Pool | `test_pool.ml` | ✅ |
| Resource | `test_resource.ml` | ✅ |
| Supervisor | `test_supervisor.ml` | ✅ |
| Promise bridge | `test_promise.ml` | ✅ |
| Observability | `test_observability.ml` | ✅ |
| Stress | `test_stress.ml` | ✅ |
| Streams | `run_js_stream_tests.ml` | ✅ |

### Deterministic Testing

All time-dependent tests use `Test_clock.runtime` for deterministic execution.
No test relies on real wall-clock timing.

## Known Limitations

1. **Single-threaded**: No true parallelism. CPU-bound work blocks the event loop.
2. **No preemptive cancellation**: Interruption is checked only at `Check`, `yield_now`, and async boundaries.
3. **Observability is minimal**: `named`, `annotate`, and span tracking are currently no-ops unless a tracer capability is provided.
4. **No structured logging format**: Log output depends on the provided logger capability; there is no default JSON or OTLP formatter.
5. **Stream combinators are pure**: The `eta_js_stream` package provides pure pull-based streams; there is no reactive push-based stream integration with the runtime scheduler.

## Migration from Prototype

If you used the pre-2026-06 prototype:

1. Replace `Runtime.run` with `Runtime.run_promise`
2. Update test runners to use `Eta_js_test.run_all` with awaited tests
3. Replace any direct `Fiber` record access with the public `Fiber` module API
4. Update stream code to use the new `eta_js_stream` package

## Package Boundaries

- `eta_js` depends only on `melange`, `js_of_ocaml` (transitive), and internal helpers.
- `eta_js` does **not** depend on `eio`, `cstruct`, or any native system libraries.
- `eta_js_stream` depends only on `eta_js`.
- `eta_js_test` depends on `eta_js`.

## Performance Notes

- JS builds target ESM (`mjs`) output.
- The scheduler uses `setTimeout(..., 0)` for yield points, which is sufficient for cooperation but introduces ~4ms latency per yield in some environments.
- For high-frequency streams, prefer pure combinators over async effects.

## Release Checklist

- [x] Native tests pass
- [x] Melange build succeeds
- [x] JS test suite passes
- [x] Stream tests pass
- [x] Parity matrix documented
- [ ] Browser smoke tests (Phase 8 deferred)
- [ ] npm packaging script (separate workstream)
- [ ] Benchmark suite (`bench/js/`)
