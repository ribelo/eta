# Eta Break Session - Comprehensive Findings

## Summary

3 bugs found, 6 red tests (5 deterministic + 1 flaky), 16+ green tests added.

| # | Module | Bug | Red Tests |
|---|--------|-----|-----------|
| 1 | `lib/http/h2/connection.ml` | Daemon cancellation misclassified as protocol violation | 2 deterministic |
| 2 | `lib/eta/effect.ml` | `retry` doesn't scope finalizers per attempt | 2 |
| 3 | `lib/http/h2/connection.ml` | `set_failure` skips handlers on exception | 1 |

Plus 1 flaky green test (test 11) that demonstrates a latent daemon scheduling bug.

## Bug 1: H2 daemon cancellation error misclassification (HTTP)

**Location:** `lib/http/h2/connection.ml` — `run_owner_loop`
**Root cause:** `Eio.Cancel.Cancelled` caught as generic `exn`, classified as
`Connection_protocol_violation` instead of `Connection_closed`
**Impact:** Wrong retryability, spurious security errors, misleading body errors
**Red tests (2 deterministic):**
- `test_h2_connection_failure_kind_on_switch_close_is_not_protocol_violation`
- `test_h2_connection_body_error_on_switch_close_is_connection_closed`

Plus 1 flaky green test:
- `test_h2_connection_switch_close_does_not_fire_security_error` (passes when writer closes flow first, fails when reader catches Cancelled first)

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
nix develop -c dune runtest test/http test/eta --force
# HTTP: 4 failures in 133 tests (1 flaky)
# Eta:  2 failures in 265 tests
# Total: 6 red tests across 3 bugs (5 deterministic + 1 flaky)
```

## Areas explored (no bugs found)

Pool, Semaphore, Channel, PubSub, Queue, Port, Par, Supervisor, Blocking,
Island, Resource, Schedule, Timeout, Race, Par, All, All_settled,
For_each_par, Acquire_release, Scoped, Catch, Finally, Repeat,
With_background, Effect.with_resource, Randomized compositions,
H2 Security, H2 Informational_filter, H2 Writer, ALPN dispatch,
H1 client (request/response, chunked, pool, cancellation, connection close),
H1 transport (TCP/TLS connect, ALPN dispatch), Retry policy.

## Additional observations (not classified as bugs)

1. **H1 pool connection close is handled by health check:** When a server
   sends `Connection: close`, the connection is marked `reusable=false`.
   The health check rejects it on next checkout. The connection is returned
   to idle but rejected before reuse. Not a correctness bug, just an
   inefficiency (connection sits in idle pool until checked out).

2. **Security module stream tracking grows without bound:**
   `response_headers_seen_by_stream` in `security.ml` is never cleaned up.
   For long-lived H2 connections with many streams, this hashtable grows.
   Very slow leak (one int per stream ID).

3. **H2 connection failure_waiters list grows without bound:**
   `register_failure_handler` adds waiters to a list. Unregistration only
   sets `active=false`. The list is only cleared when `set_failure` fires.
   For connections that never fail, inactive waiters accumulate.
