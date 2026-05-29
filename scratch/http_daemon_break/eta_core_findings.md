# Eta Break Session - Comprehensive Findings

## Summary

4 bugs found, 7 deterministic red tests + 1 flaky red test, 16+ green tests added.

| # | Module | Bug | Red Tests |
|---|--------|-----|-----------|
| 1 | `lib/http/h2/connection.ml` | Daemon cancellation misclassified as protocol violation | 2 deterministic + 1 flaky |
| 2 | `lib/eta/effect.ml` | `retry` doesn't scope finalizers per attempt | 2 |
| 3 | `lib/http/h2/connection.ml` | `set_failure` skips handlers on exception | 1 |
| 4 | `lib/http/body/stream.ml` + `lib/http/h1/h1_client.ml` | Body stream release never called when read_next raises raw exception | 1 |

## Bug 1: H2 daemon cancellation error misclassification (HTTP)

**Location:** `lib/http/h2/connection.ml` — `run_owner_loop`
**Root cause:** `Eio.Cancel.Cancelled` caught as generic `exn`, classified as
`Connection_protocol_violation` instead of `Connection_closed`
**Impact:** Wrong retryability, spurious security errors, misleading body errors
**Red tests (2 deterministic):**
- `test_h2_connection_failure_kind_on_switch_close_is_not_protocol_violation`
- `test_h2_connection_body_error_on_switch_close_is_connection_closed`

Plus 1 flaky test:
- `test_h2_connection_switch_close_does_not_fire_security_error` (fails when reader catches Cancelled first, passes when writer closes flow first)

## Bug 2: Effect.retry per-attempt resource leak (Eta core)

**Location:** `lib/eta/effect.ml` — `retry`
**Root cause:** `retry` calls `effect.eval()` without `with_finalizers` per attempt
(unlike `repeat` which creates a fresh `finalizers` ref per iteration)
**Impact:** Resources from failed attempts accumulate until scope exit
**Red tests (2):**
- `test_effect_retry_releases_resources_each_failed_attempt`
- `test_retry_resource_accumulation_systematic`

**Workaround:** Wrap retried effect body in `Effect.scoped`:
```ocaml
Effect.retry schedule pred (Effect.scoped (acquire_release ~acquire ~release |> bind body))
```

## Bug 3: H2 set_failure exception skips remaining handlers (HTTP)

**Location:** `lib/http/h2/connection.ml` — `set_failure`
**Root cause:** `List.iter` without catching individual handler exceptions
**Impact:** If one failure handler raises, subsequent handlers never fire.
Components relying on failure notifications for cleanup are broken.
**Red tests (1):**
- `test_h2_connection_failure_handler_exception_skips_others`

## Bug 4: Body stream release leak on raw exception (HTTP)

**Location:** `lib/http/body/stream.ml` — `read`; `lib/http/h1/h1_client.ml` — `source_read_some`
**Root cause:** `Body.Stream.read` uses `Effect.catch` which only catches `Error` results,
not raw OCaml exceptions. The H1 client's `source_read_some` only catches `End_of_file`;
other flow exceptions propagate as raw exns. When they reach `Body.Stream.read`, the
`Effect.catch` doesn't catch them, so `release_once` is never called.
**Impact:** Connection leak when body read fails with any exception other than EOF
(e.g. Eio.Io, Unix.Unix_error, mock flow failures).
**Red tests (1):**
- `test_body_stream_read_exception_leaks_release`

## Green tests added (16+)

- GOAWAY mid-body completes existing stream
- Timeout kills connection (documents conservative design)
- Pool stress (no resource leak)
- Semaphore stress (permit accounting)
- Channel stress (no lost messages)
- Nested scope+catch+retry (correct pattern works)
- Race+retry (resources released on scope exit)
- Security error handler not fired on switch close (flaky: latent bug)
- all_settled scoped resources released per branch
- Race many branches resource cleanup
- Randomized effect compositions (50 runs)
- Randomized race compositions (20 runs)
- Randomized all compositions (20 runs)
- for_each_par cancelled workers release
- Par scoped resource released on failure
- H1 pool Connection: close opens new connection
- All without scoped releases at scope exit

## Reproduction

```sh
# HTTP tests (7 failures: 6 deterministic + 1 flaky)
EIO_BACKEND=posix nix develop -c dune exec test/http/run.exe

# Eta core tests (2 failures, both deterministic)
nix develop -c dune exec test/eta/run.exe
```

## Areas explored (no bugs found)

Pool, Semaphore, Channel, PubSub, Queue, Port, Par, Supervisor, Blocking,
Island, Resource, Schedule, Timeout, Race, Par, All, All_settled,
For_each_par, Acquire_release, Scoped, Catch, Finally, Repeat,
With_background, Effect.with_resource, Randomized compositions,
H2 Security, H2 Informational_filter, H2 Writer, ALPN dispatch,
H1 client request/response path, H1 chunked encoding, H1 pool cancellation,
H1 pool connection close, Retry policy, Transport TCP/TLS connect.

## Additional observations (not classified as bugs)

1. **H1 pool connection close inefficiency:** When server sends `Connection: close`,
   the connection is marked `reusable=false` and returned to idle. The health check
   rejects it on next checkout. Not a leak, just an extra health check cycle.

2. **Security module stream tracking grows without bound:**
   `response_headers_seen_by_stream` in `security.ml` is never cleaned up.
   Very slow leak (one int per stream ID) for long-lived H2 connections.

3. **H2 connection failure_waiters list grows without bound:**
   `register_failure_handler` adds waiters to a list. Unregistration only sets
   `active=false`. The list is only cleared when `set_failure` fires.
   For connections that never fail, inactive waiters accumulate.
