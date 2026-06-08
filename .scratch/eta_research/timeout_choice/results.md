# Eta Timeout Choice Results

## Question

What is the right timeout shape for eta-http, and does Eta already provide the
needed primitives?

The candidates tested were:

- A. one total request timeout;
- B. eta-http-level typed timeout wrappers over Eta.Effect.timeout;
- C. a new Eta runtime timeout primitive for body idle progress;
- D. a small Eta API helper that maps timeout directly to a caller-specific
  error without exposing raw `Timeout`.

## Evidence

Command:

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/timeout_choice/timeout_choice.exe
~~~

Result:

~~~text
connect_timeout PASS error=connect_timeout
tls_handshake_timeout PASS error=tls_handshake_timeout
request_write_timeout PASS error=request_write_timeout
response_header_timeout PASS error=response_header_timeout
pool_acquire_timeout PASS error=pool_acquire_timeout
body_idle_stall PASS error=response_body_idle_timeout
fast_download_not_killed_by_idle PASS chunks=200
sse_heartbeat_happy_path PASS chunks=10
sse_stall PASS error=response_body_idle_timeout
total_request_timeout_progressing_body PASS error=total_request_timeout
single_total_timeout_kills_valid_sse PASS error=total_request_timeout
~~~

Regression added to Eta itself:

~~~sh
nix develop .#oxcaml -c dune runtest packages/eta/test --force
nix develop .#oxcaml -c eta-oxcaml-test-shipped
~~~

Both passed after adding:

- Effect / all_settled timeout scoped resource typed
- Effect / nested timeout maps outer timeout

The lab initially exposed a runtime bug: layered timeouts could surface an
internal cancellation/race cause instead of the typed timeout observed by
`Effect.catch`. `packages/eta/runtime.ml` now normalizes timeout/cancellation
races in `EP.Timeout`, and `EP.Catch` / `EP.Tap_error` normalize internal
`Raised_cause` exceptions instead of wrapping them as defects.

The pool survival smoke was rerun after the runtime fix:

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_survival/runtime_smoke.exe
~~~

Result: both internal-pool and Eta.Pool-shaped branches passed cancellation,
workload, shutdown, health rejection, and idle eviction smokes.

## Decision

1. eta-http should expose independent timeout controls:
   `connect_timeout`, `tls_handshake_timeout`, `request_write_timeout`,
   `response_header_timeout`, `response_body_idle_timeout`,
   `total_request_timeout`, and `pool_acquire_timeout`.

2. Body timeout must be an idle-progress timeout around each body read / frame
   read, not a total body deadline. This supports large slow-but-progressing
   downloads and SSE heartbeat streams while still bounding stalls.

3. A single total request timeout is not sufficient. The SSE fixture proves it
   kills a valid long-lived stream even while heartbeat chunks arrive within the
   idle deadline.

4. Eta does not need a new runtime primitive for body idle timeout. The
   behavior is expressible with `Effect.timeout` around the per-read effect,
   once nested timeout normalization is correct.

5. Eta does have a public API gap: `Effect.timeout` forces the wrapped
   effect's error row to admit raw `Timeout`. eta-http can hide this with local
   wrappers, but repeated wrappers will pollute user-facing error rows unless
   Eta adds a typed helper such as `Effect.timeout_as`.

## Rejected

- One total timeout knob: rejected by the SSE happy-path fixture.
- Body idle timeout implemented with raw Eio.Time in eta-http: rejected because
  Eta can express it after the runtime fix, and dogfooding should stay inside
  Eta primitives.
- A new low-level runtime idle-deadline primitive: rejected for v1 because the
  per-read wrapper expresses the needed behavior.

## Follow-up

- File/implement `Effect.timeout_as` or equivalent typed-timeout helper in
  Eta core.
- Use this verdict when eta-http implements its timeout config and structured
  error type.
- Validate final default values with eta-http integration fixtures; this lab
  proves shape and composability, not production default tuning.
