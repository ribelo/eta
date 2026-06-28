# R-T1 Peer Analysis Verdict

Date: 2026-05-23

Status: accepted design guidance for OS0 through OS3. This is bounded desk
research, not a production implementation proof; R-T3 remains the end-to-end
transport proof.

## Question

Which patterns from zio-telemetry, Effect @effect/opentelemetry,
opentelemetry-rust, and tracing-opentelemetry should eta-otel adopt or reject
for the clean-room rebuild on Eta primitives plus eta-http?

The probe is scoped to decisions that affect the rebuild:

- runtime context and span lifetime;
- signal separation for traces, logs, and metrics;
- hot-path callback cost versus exporter work;
- exporter lifecycle, flushing, shutdown, and backpressure;
- self-observation and recursion avoidance.

## Source Evidence

Fetch commands used for external sources:

~~~text
curl -L --fail https://raw.githubusercontent.com/zio/zio-telemetry/master/README.md -o /tmp/eta-r-t1/zio-telemetry-README.md
curl -L --fail https://raw.githubusercontent.com/zio/zio-telemetry/master/opentelemetry/src/main/scala/zio/telemetry/opentelemetry/Tracing.scala -o /tmp/eta-r-t1/zio-Tracing.scala
curl -L --fail https://raw.githubusercontent.com/open-telemetry/opentelemetry-rust/main/opentelemetry-sdk/src/trace/span_processor.rs -o /tmp/eta-r-t1/otel-rust-span_processor.rs
curl -L --fail https://crates.io/api/v1/crates/tracing-opentelemetry/0.33.0/download -o /tmp/eta-r-t1/tracing-opentelemetry-0.33.0.crate
tar -xzf /tmp/eta-r-t1/tracing-opentelemetry-0.33.0.crate -C /tmp/eta-r-t1
~~~

Local reference sources inspected:

- .reference/effect-smol/packages/opentelemetry/src/NodeSdk.ts
- .reference/effect-smol/packages/opentelemetry/src/Tracer.ts
- .reference/effect-smol/packages/opentelemetry/src/Logger.ts
- .reference/effect-smol/packages/opentelemetry/src/Metrics.ts

Evidence summary:

| Peer | Relevant evidence | Eta consequence |
| --- | --- | --- |
| zio-telemetry | Tracing.Service stores current OTel context in a FiberRef, creates root/child spans as managed values, localizes the context while an effect runs, and sets error status from the effect cause before the span closes. | Keep active context runtime/fiber-owned. Model exporter-owned lifetime with Eta Resource or acquire_release. Do not import ZIO environment/layer API surface. |
| Effect @effect/opentelemetry | NodeSdk constructs tracer/logger/metric providers with Effect.acquireRelease, forceFlush plus shutdown, interruptible release, and timeoutOption. Logger reads current span identity from fiber context. Tracer bridges effect spans into OTel context. | Otel should use scoped lifecycle internally, expose explicit flush/shutdown, and read Eta runtime context rather than inventing an eta-otel ambient context. |
| opentelemetry-rust | SpanProcessor.on_start and on_end are synchronous and must not block. BatchSpanProcessor buffers finished spans, drops when the bounded queue is full, exports due to batch size/timer/force_flush/shutdown, and reports dropped span counts. | Capability callbacks must enqueue only. Network export belongs in background Eta pipelines. Queue size, batch size, delay, export timeout, shutdown timeout, and dropped counts are part of the design, not incidental internals. |
| tracing-opentelemetry | The crate is a subscriber Layer that maps tracing spans/events into OTel spans. It has a thread-local reentrancy guard and ignores reentrant events. It supports traces and metrics, while its docs state OTel log export is a separate integration. | Keep the Eta adapter separate from the network exporter. Preserve explicit recursion avoidance with eta-http enabled:false and separate self-observation. Treat traces, logs, and metrics as distinct signal pipelines sharing resource/scope vocabulary. |

## Hypothesis Ledger

| Candidate | Why it is plausible | Evidence needed to win | Evidence that would falsify it | Current evidence | Status |
| --- | --- | --- | --- | --- | --- |
| A. Eta capability adapter plus signal-specific exporter pipelines | It preserves Eta's boundary: applications describe effects through Eta Runtime capabilities, eta-otel translates finished signals and exports them. Peers separate app tracing APIs from OTel exporters. | Functional tests still pass; R-T3 proves eta-http export without recursion; audit shows no raw HTTP client remains. | Export requires eta-otel-owned application state or capability callbacks doing network I/O. | zio-telemetry and Effect bridge runtime/fiber context into OTel; tracing-opentelemetry is an adapter Layer; Rust SpanProcessor keeps callbacks cheap and separates exporter work. | Accepted. |
| B. Clone a full OpenTelemetry SDK architecture inside eta-otel | It is complete and mirrors mature libraries. | It would need to fit Eta's small package scope without new deps or hidden global providers. | It introduces SDK-wide abstractions, dependency growth, or an ambient provider model unrelated to Eta Runtime. | Objective bounds eta-otel to Eta primitives plus eta-http. Peer SDKs are useful for lifecycle/batching semantics, not for copying architecture. | Rejected for the rebuild. |
| C. Single generic event bus for spans, logs, and metrics | It could reduce implementation surface and share batching code. | It would need to preserve per-signal semantics, payload shape, retries, and backpressure without stringly typed branching. | Signal-specific OTel requirements become untyped or logs/metrics lose distinct semantics. | Effect config wires tracer, metrics, and logger providers separately. tracing-opentelemetry explicitly separates log export from its trace/metric layer. Current R-T2 inventory maps distinct OTLP trace/log/metric shapes. | Rejected. Share infrastructure only below typed signal boundaries. |
| D. Synchronous export from tracer/logger/meter callbacks | It is the smallest implementation. | It would need to prove callbacks never block user work and never recurse. | Network I/O or retry happens on span/log/metric emission. | opentelemetry-rust documents on_start/on_end as synchronous and non-blocking; batch processors enqueue and export later. | Rejected. |
| E. Hidden global OTel provider/context | It resembles common OTel SDK setup and can be convenient. | It would need to preserve Eta's explicit Runtime boundary and test isolation. | Tests or applications can observe cross-runtime leakage, or eta-otel owns application state. | zio-telemetry and Effect use fiber/runtime context; Eta already has Runtime capabilities and W3C context in core. | Rejected for public API; internal runtime-local state is acceptable. |
| F. Explicit recursion suppression at the eta-http export call | It is already the eta-http ADR 0006 pattern and matches peer concern about reentrancy. | R-T3 proves exporter self-spans do not re-enter production export against a real collector. | Self-instrumented exporter spans are exported recursively or the disabled boundary drops application spans. | tracing-opentelemetry has an explicit reentrancy guard. Existing eta-http exposes enabled:false. | Accepted, pending R-T3 proof. |

## Adopted Patterns

1. Adapter boundary: eta-otel adapts Eta Tracer, Logger, and Meter signals to
   OTLP. It does not replace Eta Runtime and does not become an application
   framework.
2. Runtime-owned context: active span and W3C propagation remain in Eta core.
   eta-otel reads finished signals and encodes them.
3. Signal-specific pipelines: traces, logs, and metrics get typed signal paths
   with shared Resource and InstrumentationScope vocabulary.
4. Hot callbacks enqueue only: capability methods may update in-memory signal
   state and bounded queues, but never perform HTTP, retry sleeps, DNS, TLS, or
   collector parsing.
5. Explicit lifecycle: create, flush, and shutdown should have bounded timeout
   behavior. Shutdown must drain accepted signals where possible and report or
   count dropped signals.
6. Explicit backpressure: queue capacity, batch size, batch delay/export
   timeout, and dropped counts belong in config or internal stats with tests.
7. Explicit recursion boundary: exporter HTTP calls use eta-http enabled:false,
   and self-observation uses a non-exporting observer path unless R-T3 proves
   another mechanism is safe.

## Rejected Patterns

- Importing ZIO Layer/environment or Effect Layer APIs into Eta's public surface.
- A full OpenTelemetry SDK clone inside eta-otel.
- A single untyped event bus for all signals.
- Synchronous network export from span/log/metric callbacks.
- A hidden global OTel provider as the normal public setup path.
- Raw HTTP/1.1, cohttp-eio, Lwt-shaped, or generated client transport inside
  eta-otel. The rebuild consumes eta-http.
- Treating logs as trace events only. Eta has a logger capability and R-T2 maps
  OTLP log records explicitly.

## Consequences For Slices

- OS0 skeleton must introduce package audit catalogs and leave room for typed
  per-signal modules rather than one monolithic event map.
- OS1 vocabulary should promote Resource and InstrumentationScope as shared
  vocabulary and keep Span, Log, and Metric signal types distinct.
- OS2 pipelines should use Eta primitives for bounded queues, batching, flush,
  shutdown, and dropped counts. Any missing primitive belongs in Eta, not hidden
  inside eta-otel.
- OS3 exporter must use eta-http and a custom OTLP retry status classifier from
  the eta-http dogfood fix. Exporter calls must pass enabled:false.
- R-T3 remains mandatory because peer evidence supports the recursion design
  only by analogy; it does not prove eta-http enabled:false under production
  shape.

## Counterevidence and Open Work

- Peer evidence is not an OCaml fixture. It settles design direction, not
  implementation correctness.
- zio-telemetry and Effect both rely on their own environment/layer machinery;
  Eta intentionally does not have that public model.
- tracing-opentelemetry's reentrancy guard is thread-local. Eta uses Eio fibers
  and Runtime capabilities, so the exact mechanism must be Eta-shaped and
  tested in R-T3.
- Current packages/eta-otel already has tests and a working hand-rolled
  exporter, but it still owns raw Eio HTTP. Passing those tests does not prove
  the eta-http rebuild.
