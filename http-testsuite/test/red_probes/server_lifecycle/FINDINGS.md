# server_lifecycle red-probe findings

Run:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/server_lifecycle/run.exe
```

## Summary

| Probe | Status | Notes |
|-------|--------|-------|
| h1_immediate_shutdown_sleeping_handler | HANG | Shutdown Immediate does not cancel a sleeping handler; the probe hits its deadline. |
| h1_graceful_shutdown_active_upload | PASS | Graceful shutdown closes an upload-stalled connection within the timeout. |
| h1_immediate_mid_streaming_response | PASS | Streaming response connection is closed promptly by Immediate shutdown. |
| h1_shutdown_during_request_body_read | PASS | Immediate shutdown aborts a slow request-body transfer. |
| h1_many_connections_then_shutdown | HANG | Immediate shutdown leaves multiple sleeping-handler connections active past the deadline. |
| h1_repeated_start_stop | PASS | Eight start/request/stop cycles complete without obvious fd leak. |
| h1_listener_close_while_active | POLICY_GAP | A new TCP connection is accepted after `shutdown Immediate`; the listener socket is not closed. |
| h2_immediate_shutdown_sleeping_handler | HANG | Same root cause as H1: handler fibers are not cancelled by Immediate shutdown. |
| h2_graceful_shutdown_active_stream | PASS | Graceful shutdown closes an H2 connection with an open client stream. |
| h2_many_streams_then_shutdown | HANG | Immediate shutdown does not cancel H2 handler fibers; cleanup waits for them. |

## Findings

### 1. Immediate shutdown does not cancel in-flight handlers (H1)

- **Probe:** `h1_immediate_shutdown_sleeping_handler`
- **Command:** `nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/server_lifecycle/run.exe`
- **Expected:** `shutdown server Immediate` causes the active connection to close and `Server.stats` to report zero active connections well before the probe deadline (2 s).
- **Actual:** The handler sleeps for 5 s. `shutdown Immediate` returns immediately, but `active_connections` stays at 1 until the handler finishes sleeping. The probe hits its 2 s deadline.
- **Protocol/backend:** HTTP/1.1, `Eta_http_eio.Server.start_h1_on_socket`, `H1_server_connection.shutdown`.
- **Minimized input:** Single `GET /` request against a handler that calls `Eio.Time.sleep clock 5.0`; call `shutdown server Immediate` after 100 ms.
- **Classification:** likely Eta bug.

### 2. Immediate shutdown does not cancel in-flight handlers (H2)

- **Probe:** `h2_immediate_shutdown_sleeping_handler`
- **Command:** same
- **Expected:** After `shutdown Immediate`, the server process should finish promptly and the probe should return before its 3 s deadline.
- **Actual:** The H2 handler runs in a separate fiber and sleeps for 8 s. `shutdown Immediate` resolves `active_connections` to 0 quickly (the connection is unregistered), but the underlying connection switch cannot close until the handler fiber finishes sleeping. The probe hangs until its deadline.
- **Protocol/backend:** H2C, `Eta_http_eio.Server.start_h2c_on_socket`, `H2_server_connection.shutdown`.
- **Minimized input:** H2 preface + HEADERS on stream 1; handler sleeps 8 s; `shutdown Immediate` after 100 ms.
- **Classification:** likely Eta bug.

### 3. Many concurrent connections are not promptly closed by Immediate shutdown

- **Probe:** `h1_many_connections_then_shutdown`
- **Command:** same
- **Expected:** Eight concurrent connections with sleeping handlers are all closed within a few hundred milliseconds of `shutdown Immediate`.
- **Actual:** `Server.stats` still reports 8 active connections when the 4 s deadline expires.
- **Protocol/backend:** HTTP/1.1, `Eta_http_eio.Server.start_h1_on_socket`.
- **Minimized input:** Eight simultaneous `GET /` requests against a handler that sleeps 8 s; `shutdown Immediate` after 300 ms.
- **Classification:** likely Eta bug (same root cause as finding 1).

### 4. H2 many concurrent streams are not promptly closed by Immediate shutdown

- **Probe:** `h2_many_streams_then_shutdown`
- **Command:** same
- **Expected:** Eight concurrently open streams are closed quickly after `shutdown Immediate`.
- **Actual:** The connection switch cannot close until all handler fibers finish sleeping; the probe hits its 4 s deadline.
- **Protocol/backend:** H2C, `Eta_http_eio.Server.start_h2c_on_socket`.
- **Minimized input:** H2 preface + HEADERS on streams 1, 3, 5, ... 15; handler sleeps 8 s; `shutdown Immediate` after 300 ms.
- **Classification:** likely Eta bug (same root cause as finding 2).

### 5. Listener socket still accepts new TCP connections after shutdown Immediate

- **Probe:** `h1_listener_close_while_active`
- **Command:** same
- **Expected:** After `shutdown Immediate`, the listening socket is closed or otherwise refuses new connections.
- **Actual:** A `connect()` to the same port performed 100 ms after `shutdown Immediate` succeeds at the TCP level.
- **Protocol/backend:** HTTP/1.1, `Eta_http_eio.Server.start_h1_on_socket`.
- **Minimized input:** Active `GET /` connection; `shutdown Immediate`; then `Eio.Net.connect` to the same port.
- **Classification:** ambiguous policy gap. `shutdown` resolves the internal `stop` promise used by `Eio.Net.run_server`, but it does not close the listening socket, so kernel backlog can still accept a new SYN.

## Probes that passed and are worth keeping

- `h1_graceful_shutdown_active_upload`: exercises graceful shutdown while a handler is blocked reading a stalled upload.
- `h1_immediate_mid_streaming_response`: verifies that a streaming response connection is torn down by Immediate shutdown.
- `h1_shutdown_during_request_body_read`: verifies Immediate shutdown aborts an in-progress body transfer.
- `h1_repeated_start_stop`: checks for fd leaks across start/request/stop cycles.
- `h2_graceful_shutdown_active_stream`: exercises H2 graceful shutdown with an open client stream.
