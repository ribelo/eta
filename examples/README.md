# Eta Examples

These examples are executable API evidence for the recommended Eta style. They
prefer ordinary OCaml functions at the edges, lift expected typed failures with
`Effect.sync` followed by `Effect.flatten_result`, use `let@` for resource
lifetimes, and keep explicit bind calls out of user-facing code. They keep
`Eta_eio.Runtime.create`
explicit so runtime capabilities and shutdown/drain ownership remain visible.

Build all examples:

```sh
nix develop -c dune build @examples
```

Run the example tests:

```sh
nix develop -c dune runtest examples --force
```

Run one example:

```sh
nix develop -c dune exec examples/resource_retry.exe
```

The current examples cover:

- `quickstart.ml` - minimal Eio-backed Eta executable.
- `catch_recovery.ml` - pure typed failure recovery with `Effect.fold`,
  while defects remain uncaught.
- `validation_boundary.ml` - pure validation lifted with `Effect.from_result`
  rather than an unnecessary synchronous leaf.
- `sync_defect_boundary.ml` - synchronous leaves where raised exceptions remain
  Eta defects instead of typed domain failures.
- `resource_retry.ml` - scoped resource lifecycle with retry.
- `retry_schedule.ml` - composed retry schedule with deterministic jitter and
  runtime-owned sleep decisions.
- `repeat_heartbeat.ml` - scheduled unit-work recurrence without hand-written
  recursive sleep loops.
- `cached_resource.ml` - runtime-owned cached resource refresh that keeps the
  last good value after a failed refresh and records refresh diagnostics.
- `manual_resource_refresh.ml` - caller-driven cached resource refresh with
  explicit typed refresh failures.
- `scoped_resource.ml` - a resource handle registered with an enclosing scope
  and shared across later effects.
- `service_composition.ml` - ordinary OCaml dependency injection with Eta
  managing only effectful construction and cleanup.
- `source_locations.ml` - function-name spans and compiler source locations
  with `Effect.fn`.
- `tap_success.ml` - synchronous and effectful success-side observation that
  preserves the original value without hand-written bind.
- `map_projection.ml` - success-value projection with `let+` instead of
  `bind` plus `pure`.
- `stream_decode.ml` - typed decoding inside an `Eta_stream` pipeline.
- `signal_stabilization.ml` - explicit `Eta_signal` stabilization and stream
  bridge disposal lifecycle.
- `batch_concurrency.ml` - bounded parallel fan-out and collected branch
  outcomes.
- `all_health_checks.ml` - fail-fast collection of a homogeneous list of
  independent effects with `Effect.all`.
- `blueprint_names.ml` - static effect-name inspection before runtime
  interpretation, including the documented dynamic-continuation boundary.
- `bounded_channel.ml` - bounded same-domain handoff with sender backpressure,
  direct stats snapshots, and effectful typed close propagation.
- `channel_probe.ml` - non-blocking bounded-channel probes without manual
  capacity checks.
- `unbounded_queue.ml` - unbounded same-domain handoff with buffered drain,
  direct stats snapshots, and effectful typed close propagation.
- `queue_probe.ml` - non-blocking unbounded-queue probes that preserve typed
  close results.
- `mutable_ref_state.ml` - shared mutable state updates with an application
  owned `Eta.Mutable_ref`.
- `deterministic_random.ml` - seeded portable scalar and collection random
  helpers with deterministic replay.
- `duration_budget.ml` - typed duration arithmetic for retry delays and time
  budgets without raw millisecond plumbing.
- `timeout_policy.ml` - domain-typed timeout failures without manual
  race/delay plumbing.
- `uninterruptible_commit.ml` - cancellation deferral for a small critical
  effect that must finish once started.
- `error_rendering.ml` - typed failure renderers for span status, exception
  events, and finalizer diagnostics.
- `log_level_policy.ml` - log threshold parsing, rendering, and OTLP severity
  mapping without raw string/rank plumbing.
- `trace_sampling.ml` - trace sampling policies with deterministic ratio and
  parent-based decisions.
- `trace_context_boundary.ml` - W3C trace context extraction, runtime
  propagation, and header injection.
- `span_linking.ml` - current runtime span inspection and linked producer /
  consumer spans.
- `exit_cause_boundary.ml` - runtime exit conversion where typed failures can
  become `result`, while defects and finalizer failures stay as `Cause`.
- `finally_cleanup.ml` - one-shot cleanup on success, typed failure, cleanup
  failure, and cancellation with `Effect.finally`.
- `runtime_boundary.ml` - runtime execution boundaries where `run` preserves
  `Exit` and `run_exn` is only the deliberate top-level collapse path.
- `race_mirror.ml` - first successful branch wins even when another branch
  fails earlier.
- `typed_error_boundary.ml` - observe a domain error channel and map it to a
  boundary error channel.
- `admission_control.ml` - scoped semaphore permits and abortable admission
  without manual acquire/release cleanup.
- `semaphore_permits.ml` - lexical semaphore permit ownership with cleanup on
  success and typed failure.
- `connection_pool.ml` - bounded runtime-local connection reuse, stats, and
  shutdown through `Eta.Pool`.
- `pubsub_subscription.ml` - scoped publish/subscribe subscription with direct
  stats snapshots and effectful typed close propagation.
- `pubsub_poll.ml` - non-blocking scoped subscription polling without hub-level
  stats guesses.
- `http_handlers.ml` - `Eta_http.Server.Handler` adapters for sync and result
  handlers.
- `cli_business.ml` - small CLI/business workflow with argument parsing and
  retry.
- `blocking_result.ml` - blocking leaf work with expected typed failures.
- `supervisor_scope.ml` - supervised child handles that cannot escape their
  nursery.
- `background_lifecycle.ml` - a body-owned background child, backend-neutral
  `Effect.yield`, and independent foreground work with `Effect.par`.
- `daemon_drain.ml` - runtime-owned finite daemon work and explicit shutdown
  draining.
- `observability.ml` - named workflow spans, logs, events, result attributes,
  and metrics from one Eta blueprint.
- `observability_controls.ml` - tracing guards, lazy span attributes, and
  suppressed observer subtrees from the same blueprint.
- `observability_sinks.ml` - in-memory tracer/logger/meter helpers for tests
  and bounded diagnostics.
- `metric_batching.ml` - lazy batched metric emission that does no snapshot or
  allocation work when the runtime has no meter.
- `workflow_test.ml` - `eta_test` virtual-clock test for typed failure,
  timeout, and delay behavior.
