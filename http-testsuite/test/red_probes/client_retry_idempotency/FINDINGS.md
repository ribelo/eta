# client_retry_idempotency findings

Run the family:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/client_retry_idempotency/run.exe
```

## New findings

### 1. `cancellation_during_retry_delay` — outer timeout does not cancel retry delays

- **Classification:** confirmed Eta bug
- **Reproduce:**
  ```sh
  nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/client_retry_idempotency/run.exe
  ```
- **Expected behavior:** A total timeout wrapped around `Eta_http.Client.request_with_retry` should cancel an in-progress inter-attempt delay. With a 500 ms fixed retry schedule and a 200 ms outer timeout, only the first request should be attempted before the timeout fires.
- **Actual behavior:** Two request attempts are observed and the timeout fires after ~200 ms, which means the retry delay was bypassed rather than cancelled. Output:
  ```
  probe cancellation_during_retry_delay FAIL timeout did not cancel retry delay: attempts=2 elapsed_ms=200 error=...
  ```
- **Protocol/backend involved:** HTTP client retry layer (`Eta_http.Retry_policy`, `Eta_http.Client.request_with_retry`, `Eta.Effect.timeout_as`)
- **Minimized input:**
  - Policy: `Eta_http.Retry_policy.make ~mode:Default ~max_attempts:100 ~schedule:(Eta.Schedule.fixed (Eta.Duration.ms 500)) ~respect_retry_after:false ()`
  - Outer timeout: `Eta.Effect.timeout_as (Eta.Duration.ms 200) ~on_timeout:...`
  - Server/custom client returns 503 on every request.

### 2. `retry_after_respects_total_timeout` — `Retry-After` delay is not cancelled by an outer timeout

- **Classification:** confirmed Eta bug
- **Reproduce:** same command as above.
- **Expected behavior:** When the server responds with `Retry-After: 3600` and the caller wraps the retried request in a 300 ms total timeout, the timeout should fire during the retry wait and only one request attempt should be made.
- **Actual behavior:** Two request attempts are observed and the timeout fires after ~300 ms. The `Retry-After` delay is not being honoured once an outer timeout is active, allowing a second request to start before the timeout result is returned. Output:
  ```
  probe retry_after_respects_total_timeout FAIL timeout did not cancel Retry-After delay: attempts=2 elapsed_ms=300 error=...
  ```
- **Protocol/backend involved:** HTTP client retry layer (`Eta_http.Retry_policy.retry_after`, `Eta.Effect.timeout_as`)
- **Minimized input:**
  - Server returns `HTTP/1.1 503 Service Unavailable\r\nRetry-After: 3600\r\n\r\n` on every request.
  - Outer timeout: `Eta.Effect.timeout_as (Eta.Duration.ms 300) ~on_timeout:...`
  - Default retry policy (respects `Retry-After`).

### 3. `retry_after_date_format` — far-future `Retry-After` HTTP date is not capped

- **Classification:** confirmed Eta bug
- **Reproduce:** same command as above.
- **Expected behavior:** A `Retry-After` header carrying a far-future HTTP date (e.g. `Fri, 31 Dec 9999 23:59:59 GMT`) should be rejected, clamped, or capped to a reasonable maximum so the client does not block for an unbounded time.
- **Actual behavior:** `Eta_http.Retry_policy.retry_after` accepts the date and returns a delay of ~251.6 trillion milliseconds (~8000 years). If a server sends such a header, `Eta_http.Client.request_with_retry` will sleep until an outer deadline fires. Output:
  ```
  probe retry_after_date_format FAIL far-date-uncapped=251621019297231ms (potential DoS vector)
  ```
- **Protocol/backend involved:** HTTP client retry layer (`Eta_http.Retry_policy.retry_after`)
- **Minimized input:**
  - `Eta_http.Retry_policy.retry_after ~now_s:(Unix.gettimeofday ()) "Fri, 31 Dec 9999 23:59:59 GMT"`
  - Returns `Some` with a multi-thousand-year delay.

## Notes

The related probe `retry_after_delay_observed` passes: when no outer timeout is present, `Retry-After: 1` produces a ~1000 ms inter-attempt delay. This confirms that the `Retry-After` integer value itself is parsed and applied; the failures are that (a) the delay is not cancellable by an enclosing `Eta.Effect.timeout_as`, and (b) far-future HTTP dates are not bounded.

## Probes that passed and are worth keeping

- `post_default_no_retry`: confirms POST without idempotency key is not retried on 503.
- `post_idempotency_key_retries`: confirms POST with a valid `Idempotency-Key` is retried.
- `streaming_body_no_retry`: confirms one-shot `Stream` bodies are not retried.
- `streaming_body_ignores_idempotency_key`: confirms one-shot body takes precedence over an idempotency key.
- `rewindable_body_replayed`: confirms `Rewindable_stream` bodies are recreated each retry attempt.
- `retry_delay_observed`: confirms fixed-schedule delays are actually waited.
- `idempotency_key_whitespace_ignored`: confirms whitespace-only keys are ignored.
- `post_error_no_retry`: confirms non-idempotent POST is not retried on transport failure.
- `redirect_not_followed`: documents Eta's intentional no-auto-follow policy.
- `always_mode_retries_non_idempotent`: confirms `Always` mode retries non-idempotent POST when body is replayable.
- `idempotent_rewindable_retries_on_error`: confirms GET with rewindable body retries on connection failure.
