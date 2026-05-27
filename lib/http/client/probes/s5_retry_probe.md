# S5 Retry and Idempotency Probe

## Question

Can eta-http retry transient failures without retrying unsafe or one-shot
requests by default?

## Evidence

- `Http.Idempotency` classifies RFC 9110 section 9.2.2 idempotent
  methods and refuses one-shot bodies.
- `Http.Retry_policy` retries HTTP 408, 429, 502, 503, and 504 for
  replayable requests.
- `Retry-After` delta-seconds and IMF-fixdate values parse to
  `Eta.Duration.t`.
- Schedule fallback backoff is used when `Retry-After` is absent.
- `Http.request_with_retry` discards failed response bodies before the
  next attempt.
- POST/PATCH require `Idempotency-Key` or `Retry_policy.always`, and
  even `always` refuses one-shot streams.

Command:

```sh
nix develop -c dune runtest lib/http --force
```

Observed:

```text
eta-http: 66 tests passed
eta-http-security: 1 test passed
retry / idempotency classifier: PASS
retry / Retry-After parser: PASS
retry / schedule backoff: PASS
retry / succeeds on third attempt: PASS
retry / non-idempotent requires opt-in: PASS
retry / always requires replayable body: PASS
```

## Verdict

PASS for S5. The retry surface is explicit, body replayability is enforced, and
the default policy is conservative.
