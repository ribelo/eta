# client_retry_idempotency findings

Run the family:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/client_retry_idempotency/run.exe
```

## Current status

All probes in this family pass.

Resolved findings:

- `cancellation_during_retry_delay`: retry delays are lazy and cancellable by an
  enclosing total timeout, so no second request starts after the timeout fires.
- `retry_after_respects_total_timeout`: peer-directed `Retry-After` waits are
  also cancellable by the enclosing timeout.
- `retry_after_date_format`: far-future HTTP-date `Retry-After` values are
  capped by `Retry_policy.max_retry_after`.

The related probe `retry_after_delay_observed` still verifies that
`Retry-After: 1` produces an actual inter-attempt wait when no outer timeout is
present.

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
