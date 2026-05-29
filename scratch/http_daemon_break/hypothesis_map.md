# Eta HTTP Daemon Fiber Break Attempt

## Hypothesis Map

After commit 7ba588919, H2 connection reader/writer fibers are now daemons.
When a switch closes normally (all non-daemon fibers complete), daemons are
cancelled. The `run_owner_loop` catches `Eio.Cancel.Cancelled` as a generic
`exn`, which:

1. **Bug A**: Calls `security_error_handler` (reader daemon's `on_error`)
   with a fake `Connection_protocol_violation { kind = "h2_owner_loop";
   message = "Eio__Cancel.Cancelled: ..." }`. Normal lifecycle cancellation
   should NOT trigger security error callbacks.

2. **Bug B**: Sets `t.failure` to a `Connection_protocol_violation` error.
   Any body stream waiting for data sees this as a protocol violation instead
   of a clean `Connection_closed { during = Http_response }` lifecycle error.
   This also breaks retryability: `Connection_protocol_violation` is
   `Not_retryable`, but `Connection_closed` is `Retryable_if_body_replayable`.

## Attack Vectors Tested

- [x] Security error handler fires on clean switch close (Bug A) — RED (posix)
- [x] Failure handler sees Connection_protocol_violation (Bug B) — RED
- [x] Body stream error kind on daemon cancellation (Bug B) — RED
- [x] GOAWAY mid-body continues existing stream — GREEN (correct behavior)
- [x] Sequential request reuse (existing tests) — GREEN
- [x] Concurrent request streams — GREEN (existing test)
- [x] GOAWAY rejects new streams — GREEN (existing test)

## Red Tests

1. `test_h2_connection_switch_close_does_not_fire_security_error`
   — asserts security_error_handler is NOT called when switch closes after
   a completed request. FAILS on posix backend (reader daemon catches
   Cancelled before writer closes flow).

2. `test_h2_connection_failure_kind_on_switch_close_is_not_protocol_violation`
   — asserts registered failure handler sees `Connection_closed`, not
   `Connection_protocol_violation`. FAILS because writer daemon catches
   Cancelled and calls `fail_connection` with protocol violation.

3. `test_h2_connection_body_error_on_switch_close_is_connection_closed`
   — asserts body stream error on daemon cancellation is `Connection_closed`.
   FAILS because body stream's poll_error sees the misclassified failure.

## Root Cause

`run_owner_loop` in `lib/http/h2/connection.ml`:
```ocaml
| exn ->
    let kind = Error.Connection_protocol_violation
      { kind = "h2_owner_loop"; message = Printexc.to_string exn } in
    on_error kind;
    fail_connection t kind
```

No special case for `Eio.Cancel.Cancelled`. Fix direction: catch Cancelled
separately and treat it as lifecycle shutdown (call `shutdown t` like
`End_of_file`), not as a protocol error.

## Reproduction Commands

```sh
# Full red test suite (official backend):
nix develop -c dune runtest test/http --force

# Individual red tests:
EIO_BACKEND=posix nix develop -c dune exec test/http/run.exe -- test "h2-connection" 10,11,12
```

## Green Tests Added

- `test_h2_connection_goaway_mid_body_completes_existing_stream`
  — verifies server GOAWAY doesn't kill in-flight streams that fall within
  last_stream_id.
