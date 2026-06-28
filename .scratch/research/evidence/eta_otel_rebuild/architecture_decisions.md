# Eta-5zo architecture decisions

Sources:

- transient scratch notes: external exporter analysis, API gap analysis, and
  current implementation inventory (not retained in Git)
- Current Eta APIs in `lib/eta/*.mli`

## ADR-1: push-vs-poll signal ingestion

Decision: use push ingestion from Eta Runtime capability methods into an
exporter-owned bounded mailbox, then pull from that mailbox as Eta streams.

Evidence:

- Runtime capabilities are synchronous object methods; they cannot return Effect.t.
- OpenTelemetry Rust says hot-path processor callbacks should not block.
- Current eta-otel already uses push ingestion; replacing it with polling would require a global registry and would increase idle work.

Consequence:

The bounded enqueue policy is public Eta stream infrastructure:
Stream.Mailbox.offer accepts, drops, or reports closed without blocking the
application callback.

## ADR-2: single actor vs per-signal actor

Decision: use one runtime-owned exporter daemon over merged per-signal batch
streams.

Evidence:

- Current implementation already has different batch sizes and encoders per signal.
- OTLP endpoints are separate: /v1/traces, /v1/logs, /v1/metrics.
- tracing-opentelemetry separates traces/metrics and explicitly does not export logs through the same crate.
- The primitive audit requires `Stream.merge` in real eta-otel use, not only a
  tutorial example.
- `Stream.flat_map_par ~max_concurrency:3` preserves concurrent batch exports
  after the streams are merged.

Counterevidence:

A daemon per signal is slightly simpler to read locally and mirrors endpoint
separation directly.

Implementation note:

Typed `Trace_batch`, `Log_batch`, and `Metric_batch` variants preserve separate
paths, encoders, and batch sizes while a single merged stream centralizes
shutdown and lifecycle.

## ADR-3: backpressure strategy

Decision: default to bounded drop-with-count for hot-path telemetry enqueue,
not blocking application fibers.

Evidence:

- OpenTelemetry Rust processor docs say on_start runs synchronously and should not block.
- Current Eio.Stream.add can block when full.
- Telemetry loss under overload is preferable to application stalls unless the user explicitly chooses blocking.

Required test:

Backpressure overflow records a dropped counter and does not block a producer.

Implementation result:

Implemented with Mailbox.offer and verified by the eta-otel backpressure
overflow test.

## ADR-4: self-tracing recursion avoidance

Decision: exporter internals use a separate self-observer that does not enqueue
to the same exporter. Boundary drops exporter self-spans/logs/metrics from the
export sink.

Evidence:

- tracing-opentelemetry has an explicit reentrancy guard.
- Eta Runtime instrumentation calls tracer/logger/meter capabilities, so using the exporter capability to trace export work would recursively enqueue.

Required test:

Export work records self-spans to an in-memory tracer but the exporter sends no
span named with the self-export prefix.

Implementation result:

Implemented with a private Eta.Tracer.in_memory runtime for exporter daemons and
verified by the self-spans recursion test.

## ADR-5: shutdown ordering

Decision: shutdown is flush-then-stop with bounded timeout, expressed through
Effect.acquire_release, Effect.race, Effect.timeout, Capabilities.clock, and
finalizers.

Evidence:

- Effect @effect/opentelemetry force-flushes then shuts down with a timeout in Effect.acquireRelease.
- Current eta-otel flush only polls in_flight; daemon cancellation ordering is implicit in the parent Eio switch.

Required tests:

Graceful shutdown drains accepted items, stops daemons, and rejects/drops new
items consistently after close.

Implementation result:

Implemented with Mailbox.close plus bounded flush. Flush races
`Stream.Drain_counter.await_zero` against a timeout branch that sleeps
through the Eta clock capability. Each POST is raced against a deadline branch
and guarded by Effect.timeout. The shutdown test verifies accepted telemetry
drains and later submissions do not enqueue more work.

## ADR-6: transparent-cost mechanism

Decision: do not change Runtime dispatch for Eta-5zo unless no-otel benchmark
evidence shows measurable overhead attributable to eta-otel.

Evidence:

The leading algebraic-effect/PPX approach is broad and could reshape Runtime.
Eta-5zo can rebuild eta-otel without committing to that runtime-wide mechanism.

Deferred evidence:

Microbench no-otel Runtime with object noop vs a PPX-elided call site vs an
algebraic-effect handler.
