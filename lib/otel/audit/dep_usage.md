# Dependency Usage Audit

Run: bash lib/otel/audit/run.sh
Last updated: 2026-06-28T09:12:16Z
Current sites: 27

Every eta-otel call site for package-boundary or external dependencies is
listed by the generated matches below. The catalog is not a gate; it is the
truth-of-record for where eta-otel reaches outside Eta core.

Search:

    rg -n -t ocaml 'Eta_http\.|Eta_stream\.|Eio\.|Yojson\.' lib/otel

## Classification

| Dependency | Sites | Classification | Why it stays |
| --- | --- | --- | --- |
| eta-http | eta_otel.ml transport and client lifecycle | structural | OTLP/HTTP export must dogfood eta-http. Retry, body draining, response status handling, and recursion suppression all belong at this package boundary. |
| eta-stream | eta_otel.ml stream/mailbox/drain aliases and drain runner | structural | Bounded signal queues, batching, merge, and drain are the core Eta primitive shape for exporter pipelines. |
| Eio | public constructor capabilities and clock reads | structural | Applications own switch/net/clock authority. eta-otel stores only the capabilities needed to build eta-http clients and timestamp spans. |
| Yojson | OTLP/JSON encoders | structural | OTLP/JSON is the chosen wire format for this package slice. Removing Yojson requires replacing the JSON codec across all signal encoders. |

## Current Matches

<!-- BEGIN DEP_MATCHES -->
- lib/otel/eta_otel.ml:114:  Eta_http.Retry_policy.always ~max_attempts:3
- lib/otel/eta_otel.ml:118:  Eta_http.Core.Header.unsafe_of_list
- lib/otel/eta_otel.ml:124:      Eta_http.Core.Header.unsafe_add name value
- lib/otel/eta_otel.ml:125:        (Eta_http.Core.Header.remove name headers))
- lib/otel/eta_otel.ml:132:  Eta_http.Request.make ~headers:(otlp_headers config)
- lib/otel/eta_otel.ml:133:    ~body:(Eta_http.Request.Fixed [ Bytes.of_string body ])
- lib/otel/eta_otel.ml:157:  http_client : Eta_http.Client.t;
- lib/otel/eta_otel.ml:324:  Eta_http.Observability.Tracer.request_with_retry ~enabled:false
- lib/otel/eta_otel.ml:327:         Eta_http.Body.Stream.read_all response.Eta_http.Response.body
- lib/otel/eta_otel.ml:329:                (response.Eta_http.Response.status, body)))
- lib/otel/eta_otel.ml:331:         Eta.Effect.fail (`Export_error (Eta_http.Error.to_string error)))
- lib/otel/eta_otel.ml:355:    |> Eta_stream.map (fun batch -> Trace_batch batch)
- lib/otel/eta_otel.ml:359:    |> Eta_stream.map (fun batch -> Log_batch batch)
- lib/otel/eta_otel.ml:363:    |> Eta_stream.map (fun batch -> Metric_batch batch)
- lib/otel/eta_otel.ml:367:    |> Eta_stream.map (fun batch -> Self_metric_batch batch)
- lib/otel/eta_otel.ml:369:  Eta_stream.merge traces
- lib/otel/eta_otel.ml:370:    (Eta_stream.merge logs (Eta_stream.merge metrics self_metrics))
- lib/otel/eta_otel.ml:441:  |> Eta_stream.flat_map_par ~max_concurrency:3 (fun signal ->
- lib/otel/eta_otel.ml:442:         Eta_stream.from_effect (export_signal t config signal))
- lib/otel/eta_otel.ml:472:       (Eta_http.Client.shutdown t.http_client |> Eta.Effect.ignore_errors)
- lib/otel/eta_otel.ml:714:    Option.value http_client ~default:(Eta_http.Client.make_runtime ())
- lib/otel/otlp_json.ml:1:type yj = Yojson.Safe.t
- lib/otel/otlp_json.ml:146:  Yojson.Safe.to_string payload
- lib/otel/otlp_json.ml:204:  Yojson.Safe.to_string payload
- lib/otel/otlp_json.ml:376:  Yojson.Safe.to_string payload
- lib/otel/eta_otel.mli:17:  ?http_client:Eta_http.Client.t ->
- lib/otel/eta_otel.mli:41:    [http_client] defaults to {!Eta_http.Client.make_runtime}, so the exporter
<!-- END DEP_MATCHES -->
