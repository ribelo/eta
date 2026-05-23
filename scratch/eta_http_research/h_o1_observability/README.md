# H-O1 Observability

Question: can eta-http emit OTel-compatible client observability while avoiding recursive eta-otel export spans?

Artifacts:

- `semconv.ml` names the semconv keys used in the fixtures.
- `eta_http_stub.ml` is a protocol-neutral eta-http stub that emits spans, metrics, logs, and W3C propagation headers.
- `fixtures.ml` drives successful GET, connect error, TLS certificate error, TLS handshake error, HTTP 500 retry, redirect, and h2 request scenarios.
- `recursion_test.ml` models eta-otel exporting via eta-http and proves the transport-span filter reaches a quiet state.
- `semconv_attributes.md` maps emitted fields to OpenTelemetry HTTP client semconv `v1.56.0`.

Scope:

- This is a scratch proof of the public observability contract, not a promoted eta-http package.
- Eta's meter currently has gauges/counters, not histograms. The duration metric is recorded as a gauge here and documented as a production follow-up for a histogram-capable meter.
- The recursion filter suppresses eta-http client spans for eta-otel transport calls. It does not suppress logs or metrics.
