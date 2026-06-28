# ADR 0006: eta-http Observability and Exporter Recursion Boundary

Status: Accepted

## Context

S6 adds OpenTelemetry-shaped observability for eta-http without making
eta-http depend on an OTel SDK. Eta already owns tracer and meter
capabilities, so eta-http can expose wrappers that annotate Eta effects with
HTTP client semantic-convention attributes.

The recursion risk is specific: eta-otel may eventually use eta-http as its
OTLP transport. If eta-http traces those exporter POSTs and eta-otel exports
the resulting spans through eta-http again, the exporter can re-enter itself.

## Decision

eta-http observability is an explicit wrapper, not ambient instrumentation.

Public surface:

- `Http.Observability.Semconv` derives HTTP client attributes.
- `Http.Observability.Tracer.request` opens one client span around a
  request.
- `Http.Observability.Tracer.request_with_retry` opens a parent retry span
  and attempt-level child spans with `http.request.resend_count`.
- `Http.Observability.Meter.record_client_stats` records client connection
  gauges through `Eta.Capabilities.meter`.

Recursion boundary:

- exporter-owned eta-http calls use `~enabled:false` or a non-exporting/noop
  tracer boundary;
- eta-http does not special-case eta-otel internally;
- the caller that owns the exporter owns the filtering decision.

The emitted HTTP attributes use the stable OTel HTTP client names exercised by
H-O1 and S6: `http.request.method`, `url.full`, `server.address`,
`server.port`, `network.protocol.name`, `network.protocol.version`,
`http.response.status_code`, `error.type`, and `http.request.resend_count`.

## Evidence

Artifacts:

- `packages/eta-http/observability/semconv.ml`
- `packages/eta-http/observability/tracer.ml`
- `packages/eta-http/observability/meter.ml`
- `packages/eta-http/test/test_eta_http.ml`
- `.scratch/research/evidence/eta_http_v1/probes/observability/s6_observability_probe.md`
- `.scratch/research/evidence/eta_http_research/h_o1_observability/semconv_attributes.md`
- `.scratch/research/evidence/eta_http_research/h_o1_observability/results.md`

Tests:

~~~text
observability / successful GET semconv: PASS
observability / DNS error semconv: PASS
observability / TLS error semconv: PASS
observability / retry success spans: PASS
observability / redirect semconv: PASS
observability / h2 protocol attrs: PASS
observability / recursion disabled: PASS
observability / pool stats meter: PASS
~~~

Live recheck:

~~~text
eta_http_s2_honeycomb outcome=ok status=404 body_bytes=19 protocol=h2 policy=tls12_ecdhe_aead_only
eta_http_reach_summary verdict=PASS targets=13 failed=<none> protocol=auto_alpn policy=tls12_ecdhe_aead_only
~~~

## Consequences

eta-http users opt into tracing at the call site. Plain `Http.request`
does not create hidden spans.

eta-otel can use eta-http as a transport by disabling eta-http spans on the
export path, while normal application HTTP calls can still use the tracing
wrappers.

v1 does not claim full automatic redirect instrumentation or outbound trace
context injection. Those require caller-owned redirect policy and header
propagation decisions outside the S6 observability wrapper.
