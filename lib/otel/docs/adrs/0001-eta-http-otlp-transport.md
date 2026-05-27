# ADR 0001: OTLP/HTTP Export Uses eta-http

Status: Accepted

Date: 2026-05-23

## Context

Track O rebuilds eta-otel as a consumer of eta-http v1. The old exporter
owned a hand-written HTTP/1.1 POST path over Eio TCP. That duplicated transport
behavior eta-http already owns: request bodies, response body release, retry
classification, connection pooling, and HTTP error reporting.

R-T3 proved that calling eta-http from inside eta-otel can recurse into
observability unless the whole request subtree suppresses tracer, logger, and
meter observations. eta-http now exposes that through
Http.Observability.Tracer.request_with_retry ~enabled:false.

Dogfooding also exposed an eta-http API leak: the top-level client required
callers to pass an X509 authenticator even for plain OTLP/HTTP. eta-http now
supplies a lazy system-root authenticator by default so eta-otel does not
depend directly on ca-certs or x509 and plain HTTP construction does not touch
CA roots.

## Decision

eta-otel sends every trace, log, and metric batch through eta-http:

- Build a fixed-body POST request with Content-Type: application/json.
- Use Http.Client.make_h1 for the v1 exporter client.
- Use Http.Observability.Tracer.request_with_retry ~enabled:false to
  suppress recursive exporter telemetry.
- Use an OTLP-specific retry classifier: retry 429, 502, 503, and 504; do not
  retry 408.
- Drain every response body before status classification so eta-http can
  release pooled connections.
- Treat HTTP 200 and 202 as successful OTLP exports. Other final statuses are
  reported through eta-otel's on_error callback.

## Consequences

eta-otel no longer owns raw HTTP parsing, request formatting, or connection
lifecycle. Bugs in those paths are fixed once in eta-http.

eta-otel's direct dependency list becomes eta, eta-stream, eta-http, eio, and
yojson. TLS dependencies remain transitive behind eta-http.

Retry behavior is stricter than eta-http's default policy because OTLP/HTTP
does not classify 408 as retryable. This is locked by eta-otel tests for 408
and 429.

The exporter still accepts host, port, and path fields rather than a full URL.
HTTPS/custom TLS configuration is intentionally not part of this slice.

## Verification

- test/otel/run.ml has regression tests for 408 not retrying and
  429 retrying.
- scratch/eta_otel_v2/r_t3_exporter_on_eta_http/run.sh verifies 1000 spans
  against a real collector without exporting eta-http internal spans.
- Motel can be used as the local live OTLP/HTTP receiver on 127.0.0.1:27686.
