# Eta Test Backend Split

`test/test_common` owns runtime-neutral `eta_test` helper coverage and runs it
through both shared runners:

- `Eta_test.Expect` assertions for success, typed failures, defects, and
  interrupts.
- `Eta_test.Test_random.set_seed` deterministic schedule jitter replay.
- Seeded runtime jitter replay through backend-specific test-clock runtimes.
- Backend-neutral test-clock wake ordering and cascading virtual sleeps through
  the runtime adapter.
- Backend-neutral logger, tracer, and combined observed-runtime wiring.

`test/test` remains Eio-specific because the current public `eta_test`
helpers expose `Eio.Switch.t`, `Eio.Promise.t`, `Eio.Fiber.yield`, and
`Eta_eio.Runtime.create ~sleep` directly. Those tests now cover the Eio-shaped
public helper surface, while the portable semantics above run through both
runtime backends:

- `Test_clock.adjust` wake ordering and cascading sleeps
- `with_logger`, `with_tracer`, and `with_logger_and_tracer`
