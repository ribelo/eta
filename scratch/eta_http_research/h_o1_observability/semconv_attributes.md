# H-O1 Semconv Attribute Matrix

Semconv source: OpenTelemetry HTTP client spans documentation, current published docs as fetched on 2026-05-23 from https://opentelemetry.io/docs/specs/semconv/http/http-spans/. The page references semantic convention version `v1.56.0` for the HTTP client attributes used by this lab.

Eta span attributes are represented as `(string * string)` pairs, so integer-valued semconv attributes are stored as decimal strings in the scratch fixtures. The logical attribute name and value domain match the semconv field.

| Concern | Emitted attribute / metric / log field | Notes |
| --- | --- | --- |
| HTTP method | `http.request.method` | Required on client spans. Span name is the method (`GET`, `POST`). |
| URL | `url.full` | Full outbound URL, including query, per semconv. Error redaction remains a separate H-D-Errors projection rule. |
| Peer host | `server.address` | Host parsed from the URL. |
| Peer port | `server.port` | Decimal string for Eta attrs. |
| Protocol name | `network.protocol.name=http` | Present on h1 and h2. |
| Protocol version | `network.protocol.version=1.1` or `2` | Distinguishes h1 and h2 fixtures. |
| User agent | `user_agent.original=eta-http/0.1` | Stable scratch value. |
| Response status | `http.response.status_code` | Decimal string in Eta attrs; checked for 200, 301, and 500. |
| Retry / redirect resend | `http.request.resend_count` | `0` for first attempt, `1` for retry/redirect follow-up and parent summary. |
| Error classification | `error.type` | Low-cardinality value from H-D-Errors (`connect_timeout`, `tls_certificate_error`, `tls_handshake_error`, `http_status_5xx`). |
| Duration metric | `http.client.request.duration` | Gauge in seconds in this scratch lab because Eta has no histogram primitive yet. Production eta-http should use a histogram once the meter supports it. |
| Active requests metric | `http.client.active_requests` | Gauge with unit `{request}`. |
| Request size metric | `http.client.request.body.size` | Gauge with unit `By`. |
| Response size metric | `http.client.response.body.size` | Gauge with unit `By`. |
| Pool active metric | `eta.http.client.pool.active` | Eta extension; connection-pool stats have no direct HTTP semconv metric. |
| Pool idle metric | `eta.http.client.pool.idle` | Eta extension. |
| Connect/TLS/retry/redirect logs | `event.name`, `error.type`, scenario-specific fields | Structured logs are emitted through `Effect.log`; the runtime fills trace/span IDs. |
| Propagation | W3C `traceparent`, `tracestate`, `baggage` headers | Produced via `Trace_context.inject` from the active client span context. |

Recursion filter:

- Normal application HTTP calls emit client spans.
- eta-otel transport calls set `suppress_client_spans=true` on eta-http instrumentation.
- Metrics/logs may still be emitted, but the client spans that would be re-exported by eta-otel are suppressed.

## S6 Package Subset

`packages/eta-http/observability/` promotes the stable span and pool-stat
subset from this lab: request/response/error/retry/protocol attributes,
`http.response.header.location` derivation for redirect evidence, recursion
suppression through `~enabled:false`, and eta-http connection gauges.

The package does not yet emit W3C propagation headers, structured log events,
duration histograms, body-size metrics, or automatic redirect-follow child
spans. Those require a propagation/redirect policy boundary outside S6.
