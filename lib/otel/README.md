# eta-otel

OTLP/JSON exporter for [Eta](../eta)'s tracer, logger, and meter
capabilities.

OpenTelemetry Protocol implementation with hand-written JSON encoders and
eta-http transport. Batching, stream merging, timeout, retry, backpressure,
cached exporter configuration, and daemon lifecycle are expressed as Eta
effects and Eta streams.
**No protobuf, no `cohttp`, no ambient dependency context.** The direct
dependency closure is `eta`, `eta-stream`, `eta-http`, `eio`, and
`yojson`; TLS dependencies stay behind eta-http.

## Why a separate package?

Core `eta` ships with `Tracer.in_memory` (for tests) and `Tracer.noop`
(default). Sending spans over the wire pulls in a network stack and a wire
format, which is a packaging concern, not a language concern. `eta-otel`
implements Eta's observability capabilities against OTLP/JSON so apps that
want real export can opt in without bloating the core library.

## Install

```sh
opam install eta-otel
```

## Minimal example

```ocaml
open Eta

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let exporter =
    Otel.create ~sw ~net ~clock
      ~host:"127.0.0.1" ~port:4318
      ~service_name:"my-app"
      ~service_version:"0.1.0"
      ()
  in
  let rt =
    Runtime.create ~sw ~clock ~tracer:(Otel.tracer exporter) ()
  in
  let work =
    Effect.fn __POS__ __FUNCTION__
      (Effect.par
         (Effect.named "left"  (Effect.pure ()))
         (Effect.named "right" (Effect.fail `Boom)
          |> Effect.catch (fun (`Boom : [ `Boom ]) -> Effect.pure ())))
  in
  let _ = Runtime.run rt work in
  Otel.flush exporter
```

That program emits one parent span with two children. `Effect.fn __POS__
__FUNCTION__` records the current source location as a `loc` attribute and
names the span after the enclosing OCaml binding.

Typed failures render as `"<typed failure>"` unless the effect supplies a typed
renderer before the runtime emits the span status:

```ocaml
Effect.fn
  ~error_renderer:(function `Boom -> "boom")
  __POS__ __FUNCTION__
  (Effect.fail `Boom)
```

## Propagation

Eta core owns W3C propagation parsing because sampling and baggage affect the
runtime, not only the exporter. Use `Trace_context.extract` at inbound
boundaries and `Effect.with_context` around the request effect:

```ocaml
let request headers =
  let body = Effect.named_kind ~kind:Capabilities.Server "http.request" work in
  match Trace_context.extract headers with
  | None -> body
  | Some ctx -> Effect.with_context ctx body
```

Outbound clients can inject the active context:

```ocaml
let outbound_headers =
  Effect.current_context
  |> Effect.map (function
       | None -> []
       | Some ctx -> Trace_context.inject ctx)
```

The exporter preserves the incoming trace ID, parent span ID, sampled flag,
and `tracestate` on emitted spans. `baggage` is carried in the runtime
context and reinjected on outbound boundaries; it is not an OTLP span field.

## Configuration

`Otel.create` accepts:

| label             | default          | meaning                                      |
| ----------------- | ---------------- | -------------------------------------------- |
| `~host`           | `"127.0.0.1"`    | OTLP collector host                          |
| `~port`           | `4318`           | OTLP/HTTP port                               |
| `~traces_path`    | `"/v1/traces"`   | OTLP traces endpoint                         |
| `~logs_path`      | `"/v1/logs"`     | OTLP logs endpoint                           |
| `~metrics_path`   | `"/v1/metrics"`  | OTLP metrics endpoint                        |
| `~service_name`   | `"eta"`        | `service.name` resource attribute            |
| `~service_version`| `None`           | `service.version` resource attribute         |
| `~resource_attrs` | `[]`             | extra resource attributes (key, value pairs) |
| `~scope_name`     | `"eta"`        | OTel instrumentation scope name              |
| `~queue_capacity` | `1024`           | bounded mailbox capacity per signal          |
| `~on_error`       | prints to stderr | callback for non-fatal export errors         |
| `~on_send`        | no-op            | test hook called before each HTTP POST       |

The exporter starts one Eta runtime daemon on the supplied switch. That daemon
loads cached exporter configuration through `Eta.Resource`, consumes bounded
`Stream.Mailbox` sources, merges signal streams with `Stream.merge`,
exports batches with bounded parallelism, and decrements in-flight counters
through Eta finalizers. Export POSTs go through eta-http with observability
suppressed so exporter-internal pool and transport spans are not re-exported.
Flush waits on `Stream.Drain_counter.await_zero` instead of fixed-interval
polling.

`Otel.flush ?timeout_s exporter` blocks until the queue is drained or
the timeout elapses. Call it before the program exits to avoid losing spans.

`Otel.shutdown ?timeout_s exporter` closes the signal mailboxes, drains
already accepted telemetry, and drops signals submitted after shutdown.

## Self Metrics

eta-otel emits exporter self-metrics to the configured metrics endpoint.
Trace and log exports enqueue one metrics batch after the export attempt;
metrics exports append their own self-metrics directly to the outgoing OTLP
payload. That keeps exporter metrics observable without recursively scheduling
more metric exports.

The current self-metrics are:

| name                      | kind              | attrs    | meaning                       |
| ------------------------- | ----------------- | -------- | ----------------------------- |
| `eta_otel.export.batches` | monotonic counter | `signal` | export batch attempts         |
| `eta_otel.export.items`   | monotonic counter | `signal` | items attempted for export    |
| `eta_otel.queue.depth`    | gauge             | `queue`  | current signal queue depth    |
| `eta_otel.queue.dropped`  | gauge             | `queue`  | cumulative signal queue drops |
| `eta_otel.in_flight`      | gauge             | none     | in-flight exporter work       |

## Pointing at a collector

`eta-otel` sends OTLP/HTTP JSON with `Content-Type: application/json`.
Any OTLP/HTTP-JSON-capable collector works:

- [otelcol](https://opentelemetry.io/docs/collector/) with a `otlp/http`
  receiver
- [motel](https://github.com/lovettchris/motel) (lightweight local store
  used during this package's development)
- the OTLP/JSON endpoint of any commercial backend that supports it

## What this package does *not* do

- **Sampler decisions.** Sampling is made by `Runtime.create ?sampler`; the
  exporter receives only spans the runtime decided to record.
- **Custom TLS policy.** The current constructor exposes host, port, and path
  settings for OTLP/HTTP. TLS policy remains inside eta-http and is not yet
  configurable through eta-otel.
- **Protobuf.** OTLP/JSON only.

If you need a different transport, write an alternate adapter against Eta's
observability capabilities using
[`ocaml-opentelemetry`](https://github.com/ocaml-tracing/ocaml-opentelemetry).
The trait stays the same; only the backend swaps.

## License

MIT, same as eta.
