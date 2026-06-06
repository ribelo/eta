# Eta OTel Tutorial

`eta-otel` exports Eta traces, logs, and metrics to an OTLP/HTTP JSON collector.
Applications still own state and dependency wiring. Eta owns effect
description, interpretation, and the observability capabilities.

## Minimal Program

Run this with an OTLP/HTTP JSON collector on `127.0.0.1:4318`.

```ocaml
open Eta

let work =
  Effect.named "http.request"
    (Effect.log "handling request"
    |> Effect.bind (fun () ->
           Effect.metric_update ~name:"requests.total"
             ~kind:Capabilities.Counter_monotonic (Capabilities.Int 1))
    |> Effect.bind (fun () -> Effect.pure "ok"))

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let exporter =
    Eta_otel.create ~sw ~net ~clock
      ~host:"127.0.0.1" ~port:4318
      ~service_name:"eta-demo"
      ~service_version:"0.1.0"
      ()
  in
  let rt =
    Runtime.create ~sw ~clock
      ~tracer:(Eta_otel.tracer exporter)
      ~logger:(Eta_otel.logger exporter)
      ~meter:(Eta_otel.meter exporter)
      ()
  in
  ignore (Runtime.run rt work : (string, _) Exit.t);
  Eta_otel.shutdown exporter
```

`shutdown` closes the exporter mailboxes and waits for accepted telemetry to
drain. Use `flush` instead if the exporter should remain open.

## Explicit Dependencies

Pass application dependencies as normal OCaml values. Do not model them as an
Eta environment.

```ocaml
let load_user db user_id =
  Effect.named "db.load_user" (Effect.sync (fun () -> Db.load_user db user_id))

let request db user_id =
  Effect.named "load-user" (load_user db user_id)
```

This keeps the OTel adapter small: capability methods enqueue telemetry, and
Eta stream programs batch and export it.

## Exporter Pipeline

The hot path is a synchronous capability callback. It mutates local span state
or calls `Eta_stream.Mailbox.offer`; it does not perform network I/O.

Inside the exporter daemon, each mailbox becomes a stream of online batches:

```ocaml
let traces =
  Mailbox.to_batch_stream ~max:32 trace_mailbox
  |> Stream.map (fun batch -> Trace_batch batch)
```

The three signal streams are merged into one export program:

```ocaml
Stream.merge traces (Stream.merge logs metrics)
|> Stream.flat_map_par ~max_concurrency:3 export_one_batch
|> Eta_stream.run_drain
```

This is why eta-otel has one runtime-owned daemon but still preserves separate
trace, log, and metric endpoints and batch sizes.

## OTLP/HTTP Transport

Each batch is encoded as OTLP/JSON and posted through eta-http:

```ocaml
Eta_http.Observability.Tracer.request_with_retry
  ~enabled:false
  ~policy:otlp_retry_policy
  http_client request
```

The `~enabled:false` boundary suppresses tracer, logger, meter, and automatic
instrumentation for the exporter transport subtree. eta-http can still own
connection pooling, response-body draining, retry, and shutdown; eta-otel does
not need raw Eio TCP.

The OTLP retry policy retries `429`, `502`, `503`, and `504`. It does not retry
`408`, because OTLP/HTTP does not define that as retryable for this exporter.
Successful exports are HTTP `200` or `202`.

## Cached Configuration

Resolved endpoint and resource attributes are loaded once through `Resource.t`
when the exporter starts.

```ocaml
Resource.manual
  (Effect.named "eta_otel.config"
     (Effect.named "eta_otel.config.load" (Effect.sync (fun () -> config))))
```

The daemon reads that resource before consuming signal streams. There is no
ambient environment channel; configuration remains an ordinary OCaml value.

## Backpressure

Each signal has a bounded mailbox. The default capacity is `1024`.

```ocaml
let exporter =
  Eta_otel.create ~sw ~net ~clock
    ~queue_capacity:4096
    ~service_name:"api"
    ()
```

When a mailbox is full, new telemetry is dropped and counted. Exporter hot paths
do not block application fibers waiting for collector recovery.

`flush` is intentionally ordinary OCaml, but it runs an Eta effect that races
`Eta_stream.Drain_counter.await_zero` against a timeout branch. The timeout
branch uses the Eta clock capability produced by `Capabilities.clock_of_eio`.

## Error Handling

Export failures are non-fatal. eta-http classifies transport failures and
status codes, drains response bodies, and retries according to the OTLP retry
policy. eta-otel wraps the POST in a six-second `Effect.timeout_as` and reports
the final failure through `~on_error`.

```ocaml
let exporter =
  Eta_otel.create ~sw ~net ~clock
    ~on_error:(fun msg -> prerr_endline ("OTLP export failed: " ^ msg))
    ()
```

The OTLP body is still built on the exporter daemon. Use a collector or proxy
when the deployment needs TLS termination or production buffering.

## Self Observation

Exporter internals use a private in-memory tracer. Those spans are available to
tests through `Eta_otel.Internal.self_spans`, but they are not sent to the OTLP
sink.

eta-otel also exports its own health metrics through the configured metrics
endpoint:

| name | kind | attrs | meaning |
| --- | --- | --- | --- |
| `eta_otel.export.batches` | monotonic counter | `signal` | export batch attempts |
| `eta_otel.export.items` | monotonic counter | `signal` | items attempted for export |
| `eta_otel.queue.depth` | gauge | `queue` | current queue depth |
| `eta_otel.queue.dropped` | gauge | `queue` | cumulative queue drops |
| `eta_otel.in_flight` | gauge | none | in-flight exporter work |

Trace and log exports enqueue one follow-up metrics batch while the original
batch is still counted as in-flight. Metrics exports append their own
self-metrics directly to the outgoing payload, so metrics export does not
schedule another metrics export.

## Limits

- Transport is OTLP/HTTP through eta-http's h1 client.
- `Eta_otel.create` currently builds `http://host:port/path`; HTTPS/custom TLS
  is not exposed on eta-otel's constructor.
- Wire format is OTLP/JSON, not protobuf.
- Mailbox overflow drops telemetry by design.
- `Island.run` is not used because the encoder benchmark did not prove a
  CPU-offload benefit.
- `Effect.blocking` is not used because eta-http already exposes an Eta effect
  for transport.
- Historical scratch files may contain old dependency-row experiments. Current
  benchmark code and results use explicit dependency naming.
