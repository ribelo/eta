# External exporter analysis

Fetched 2026-05-22.

## ZIO Telemetry

Sources:

- https://raw.githubusercontent.com/zio/zio-telemetry/master/README.md
- https://raw.githubusercontent.com/zio/zio-telemetry/master/opentelemetry/src/main/scala/zio/telemetry/opentelemetry/Tracing.scala

Relevant evidence:

- README describes ZIO Telemetry as purely functional and type-safe, with OpenTelemetry support.
- Tracing.scala models current context as a FiberRef[Context].
- Span lifetime is scoped through ZManaged: createRoot returns UManaged[Context], and createChildOf returns UManaged[Context].
- Running an effect inside a span uses localized fiber context and taps the cause to set error status before the span closes.

Eta consequence:

- Span context should stay runtime/fiber-local, not global mutable state.
- Exporter lifecycle should be scoped and finalizable, which supports using Effect.acquire_release or a Resource.t wrapper for eta-otel internals.
- ZIO's environment/layer machinery is not imported into Eta; ordinary values and explicit runtime services remain the boundary.

Decision for Eta:

Adopt scoped lifetime and fiber-local context principles. Do not copy ZIO's environment/layer surface.

## Effect @effect/opentelemetry

Sources:

- https://raw.githubusercontent.com/Effect-TS/effect/main/packages/opentelemetry/README.md
- https://raw.githubusercontent.com/Effect-TS/effect/main/packages/opentelemetry/src/NodeSdk.ts
- https://raw.githubusercontent.com/Effect-TS/effect/main/packages/opentelemetry/src/Tracer.ts
- https://raw.githubusercontent.com/Effect-TS/effect/main/packages/opentelemetry/src/Logger.ts
- https://raw.githubusercontent.com/Effect-TS/effect/main/packages/opentelemetry/src/Metrics.ts

Relevant evidence:

- NodeSdk.layerTracerProvider uses Layer.scoped and Effect.acquireRelease.
- Provider shutdown is force-flush plus shutdown, ignored/logged, interruptible, and bounded by Effect.timeoutOption.
- Logger integration builds an effectful logger from a provider and reads span identity from effect context/fiber refs.
- Metrics expose producer/reader registration as scoped effects.

Eta consequence:

- Eta should use Effect.acquire_release and Effect.timeout for exporter lifecycle and shutdown ordering.
- Eta should keep the public API simple; it does not have Layer, so the closest idiom is either explicit create plus flush or an effectful resource constructor.
- The exporter can self-instrument with Eta spans only if it uses a separate non-exporting tracer/logger/meter; otherwise export work would recursively enqueue itself.

Decision for Eta:

Use explicit Eta resource/lifecycle primitives internally. Keep compatibility with Otel.create, but design the implementation around a scoped program.

## OpenTelemetry Rust SDK

Source:

- https://raw.githubusercontent.com/open-telemetry/opentelemetry-rust/main/opentelemetry-sdk/src/trace/span_processor.rs

Relevant evidence:

- The SDK separates the hot-path span processor interface from exporters.
- on_start is synchronous on the thread starting the span and must not block.
- Batch processor defaults are explicit: schedule delay, max queue size, max batch size, export timeout, and max concurrent exports.
- Processors are shared by all tracers from a provider and invoked in order.

Eta consequence:

- Capability methods must not perform network export.
- Queue/backpressure policy is a first-class design decision, not an incidental Eio.Stream.create 1024.
- Export timeout and shutdown timeout need tests.

Decision for Eta:

Preserve cheap capability methods and make exporter queue/backpressure settings explicit in eta-otel config, even if defaults match the current implementation.

## tracing-opentelemetry

Sources:

- https://docs.rs/tracing-opentelemetry/latest/tracing_opentelemetry/
- https://crates.io/api/v1/crates/tracing-opentelemetry/0.33.0/download

Relevant evidence from crate source:

- The crate is a tracing_subscriber Layer, not an exporter implementation.
- It maps tracing span fields and events into OpenTelemetry span builders.
- It has an explicit reentrancy guard: a thread-local INSIDE_TRACING and prevent_reentrant_call.
- It documents that logging to OpenTelemetry is not supported by that crate; logs are a separate integration.

Eta consequence:

- Eta's exporter should also guard self-observation explicitly.
- Per-signal handling is legitimate: traces, logs, and metrics have different semantics and batch sizes.
- The adapter layer and the network exporter are separate responsibilities.

Decision for Eta:

Adopt an explicit recursion guard / separate self-observer. Keep trace/log/metric actors separate unless evidence shows one actor is simpler and no slower.

