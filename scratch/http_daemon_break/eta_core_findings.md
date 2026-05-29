# Eta Break Session - Comprehensive Findings

## Summary

3 bugs found, 6 red tests (5 deterministic + 1 flaky), 15 green tests added.

| # | Module | Bug | Red Tests |
|---|--------|-----|-----------|
| 1 | `lib/http/h2/connection.ml` | Daemon cancellation misclassified as protocol violation | 2 (deterministic) |
| 2 | `lib/eta/effect.ml` | `retry` doesn't scope finalizers per attempt | 2 |
| 3 | `lib/http/h2/connection.ml` | `set_failure` skips handlers on exception | 1 |

Plus 1 flaky green test (test 11) that demonstrates the latent daemon scheduling bug.

## Bug 1: H2 daemon cancellation error misclassification (HTTP)

**Location:** `lib/http/h2/connection.ml` — `run_owner_loop`
**Root cause:** `Eio.Cancel.Cancelled` caught as generic `exn`, classified as
`Connection_protocol_violation` instead of `Connection_closed`
**Impact:** Wrong retryability, spurious security errors, misleading body errors
**Red tests (3):**
- `test_h2_connection_switch_close_does_not_fire_security_error`
- `test_h2_connection_failure_kind_on_switch_close_is_not_protocol_violation`
- `test_h2_connection_body_error_on_switch_close_is_connection_closed`

## Bug 2: Effect.retry per-attempt resource leak (Eta core)

**Location:** `lib/eta/effect.ml` — `retry`
**Root cause:** `retry` calls `effect.eval()` without `with_finalizers` per attempt
**Impact:** Resources from failed attempts accumulate until scope exit
**Red tests (2):**
- `test_effect_retry_releases_resources_each_failed_attempt`
- `test_retry_resource_accumulation_systematic`

## Bug 3: H2 set_failure exception skips remaining handlers (HTTP)

**Location:** `lib/http/h2/connection.ml` — `set_failure`
**Root cause:** `List.iter` without catching individual handler exceptions
**Impact:** If one failure handler raises, subsequent handlers never fire.
Components relying on failure notifications for cleanup are broken.
**Red tests (1):**
- `test_h2_connection_failure_handler_exception_skips_others`

## Green tests added (15)

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

## Green tests added (14)

- GOAWAY mid-body completes existing stream
- Timeout kills connection (documents conservative design)
- Pool stress (no resource leak)
- Semaphore stress (permit accounting)
- Channel stress (no lost messages)
- Nested scope+catch+retry (correct pattern works)
- Race+retry (resources released on scope exit)
- Security error handler not fired on switch close
- all_settled scoped resources released per branch
- Race many branches resource cleanup
- Randomized effect compositions (50 runs)
- Randomized race compositions (20 runs)
- Randomized all compositions (20 runs)
- for_each_par cancelled workers release
- Par scoped resource released on failure

## Reproduction

```sh
nix develop -c dune runtest test/http test/eta --force
# HTTP: 3 failures in 131 tests
# Eta: 2 failures in 264+ tests
# Total: 5 red tests across 2 bugs
```

## Areas explored (no bugs found)

Pool, Semaphore, Channel, PubSub, Queue, Port, Par, Supervisor, Blocking,
Island, Resource, Schedule, Timeout, Race, Par, All, All_settled,
For_each_par, Acquire_release, Scoped, Catch, Finally, Repeat,
With_background, Effect.with_resource, Randomized compositions,
H2 Security, H2 Informational_filter, H2 Writer, ALPN dispatch.