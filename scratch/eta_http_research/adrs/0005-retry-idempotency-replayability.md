# ADR 0005: eta-http Retry, Idempotency, and Body Replayability

Status: Accepted

## Context

S5 consumes three earlier decisions:

- H-D-Errors gives each eta-http failure a retryability classification.
- S3 added explicit request-body shapes: fixed bytes, one-shot streams, and
  rewindable streams.
- RFC 9110 section 9.2.2 defines GET, HEAD, PUT, DELETE, OPTIONS, and TRACE as
  idempotent methods. POST and PATCH are not idempotent by method.

Retry correctness depends on both request semantics and body replayability. A
safe method with a one-shot upload still cannot be retried automatically.

## Decision

eta-http exposes:

- `Eta_http.Idempotency` for method and body replayability classification.
- `Eta_http.Retry_policy.t` for retry decisions.
- `Eta_http.request_with_retry` and
  `Eta_http.Client.request_with_retry` as wrappers around the existing request
  path.

Default retry behavior:

- retry replayable idempotent requests on transient transport failures;
- retry HTTP 408, 429, 502, 503, and 504;
- honor `Retry-After` delta-seconds and IMF-fixdate values;
- fall back to exponential backoff capped at 30s with full jitter;
- do not retry POST/PATCH unless the request carries `Idempotency-Key`;
- never retry one-shot stream bodies.

`Retry_policy.always` opts non-idempotent requests into retry only when the
body is replayable. It still refuses one-shot streams.

## Evidence

Artifacts:

- `packages/eta-http/client/idempotency.ml`
- `packages/eta-http/client/retry.ml`
- `packages/eta-http/test/test_eta_http.ml`
- `packages/eta-http/client/probes/s5_retry_probe.md`

Tests:

~~~text
retry / idempotency classifier: PASS
retry / Retry-After parser: PASS
retry / schedule backoff: PASS
retry / succeeds on third attempt: PASS
retry / non-idempotent requires opt-in: PASS
retry / always requires replayable body: PASS
~~~

## Consequences

The request record stays stable. Retry is an explicit wrapper, so callers that
need exact attempt control can keep using `Eta_http.request`.

The current wrapper does not expose attempt callbacks or observability hooks.
S6 owns retry child spans and retry-decision logging.
