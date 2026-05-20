# effet-otel

OTLP/JSON exporter for [Effet](../effet)'s tracer, logger, and meter
capabilities.

Hand-rolled OpenTelemetry Protocol implementation in ~250 LOC: JSON encoder,
HTTP/1.1 client over Eio TCP, batching daemon. **No protobuf, no TLS stack,
no `cohttp`, no `ambient-context`.** The dependency closure is just `effet`
and `eio`.

## Why a separate package?

Core `effet` ships with `Tracer.in_memory` (for tests) and `Tracer.noop`
(default). Sending spans over the wire pulls in a network stack and a wire
format, which is a packaging concern, not a language concern. `effet-otel`
implements Effet's observability capabilities against OTLP/JSON so apps that
want real export can opt in without bloating the core library.

## Install

```sh
opam install effet-otel
```

## Minimal example

```ocaml
open Effet

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let exporter =
    Effet_otel.create ~sw ~net ~clock
      ~host:"127.0.0.1" ~port:4318
      ~service_name:"my-app"
      ~service_version:"0.1.0"
      ()
  in
  let rt =
    Runtime.create ~sw ~clock ~tracer:(Effet_otel.tracer exporter) ~env:() ()
  in
  let work =
    Effect.fn __POS__ __FUNCTION__
      (Effect.par
         (Effect.named "left"  (Effect.pure ()))
         (Effect.named "right" (Effect.fail `Boom)
          |> Effect.catch (fun (`Boom : [ `Boom ]) -> Effect.pure ())))
  in
  let _ = Runtime.run rt work in
  Effet_otel.flush exporter
```

That program emits one parent span with two children. `Effect.fn __POS__
__FUNCTION__` records the current source location as a `loc` attribute and
names the span after the enclosing OCaml binding.

## Propagation

Effet core owns W3C propagation parsing because sampling and baggage affect the
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

`Effet_otel.create` accepts:

| label             | default          | meaning                                      |
| ----------------- | ---------------- | -------------------------------------------- |
| `~host`           | `"127.0.0.1"`    | OTLP collector host                          |
| `~port`           | `4318`           | OTLP/HTTP port                               |
| `~traces_path`    | `"/v1/traces"`   | OTLP traces endpoint                         |
| `~logs_path`      | `"/v1/logs"`     | OTLP logs endpoint                           |
| `~metrics_path`   | `"/v1/metrics"`  | OTLP metrics endpoint                        |
| `~service_name`   | `"effet"`        | `service.name` resource attribute            |
| `~service_version`| `None`           | `service.version` resource attribute         |
| `~resource_attrs` | `[]`             | extra resource attributes (key, value pairs) |
| `~scope_name`     | `"effet"`        | OTel instrumentation scope name              |
| `~on_error`       | prints to stderr | callback for non-fatal export errors         |

The exporter forks one background fiber on the supplied switch. That fiber
drains the in-memory queues and POSTs JSON to the configured OTLP paths.

`Effet_otel.flush ?timeout_s exporter` blocks until the queue is drained or
the timeout elapses. Call it before the program exits to avoid losing spans.

## Pointing at a collector

`effet-otel` speaks plain HTTP/1.1 with `Content-Type: application/json`.
Any OTLP/HTTP-JSON-capable collector works:

- [otelcol](https://opentelemetry.io/docs/collector/) with a `otlp/http`
  receiver
- [motel](https://github.com/lovettchris/motel) (lightweight local store
  used during this package's development)
- the OTLP/JSON endpoint of any commercial backend that supports it

## What this package does *not* do

- **Sampler decisions.** Sampling is made by `Runtime.create ?sampler`; the
  exporter receives only spans the runtime decided to record.
- **TLS.** Plain HTTP only. Run a sidecar collector or terminate TLS
  upstream.
- **Protobuf.** OTLP/JSON only.

If you need a different transport, write an alternate adapter against Effet's
observability capabilities using
[`ocaml-opentelemetry`](https://github.com/ocaml-tracing/ocaml-opentelemetry).
The trait stays the same; only the backend swaps.

## License

MIT, same as effet.
