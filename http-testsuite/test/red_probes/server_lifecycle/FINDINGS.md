# server_lifecycle red-probe findings

Run:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/server_lifecycle/run.exe
```

## Summary

| Probe | Status | Notes |
|-------|--------|-------|
| h1_immediate_shutdown_sleeping_handler | PASS | Immediate shutdown interrupts a sleeping handler and drops the active connection. |
| h1_graceful_shutdown_active_upload | PASS | Graceful shutdown closes an upload-stalled connection within the timeout. |
| h1_immediate_mid_streaming_response | PASS | Streaming response connection is closed promptly by Immediate shutdown. |
| h1_shutdown_during_request_body_read | PASS | Immediate shutdown aborts a slow request-body transfer. |
| h1_many_connections_then_shutdown | PASS | Immediate shutdown closes concurrent sleeping-handler connections. |
| h1_repeated_start_stop | PASS | Eight start/request/stop cycles complete without obvious fd leak. |
| h1_listener_close_while_active | PASS | The listener is closed by `shutdown Immediate`. |
| h2_immediate_shutdown_sleeping_handler | PASS | Immediate shutdown interrupts sleeping H2 handler fibers. |
| h2_graceful_shutdown_active_stream | PASS | Graceful shutdown closes an H2 connection with an open client stream. |
| h2_many_streams_then_shutdown | PASS | Immediate shutdown closes concurrent H2 streams promptly. |

## Resolved Findings

- Immediate shutdown now interrupts H1 and H2 handlers that are still
  constructing responses.
- Immediate shutdown now closes multiple active H1 connections and H2 streams
  promptly.
- Server handles now close their registered listener resources during shutdown,
  so a new TCP connection after `shutdown Immediate` is refused or closed.

## Probes that passed and are worth keeping

- `h1_immediate_shutdown_sleeping_handler`: verifies sleeping H1 handlers are
  interrupted by Immediate shutdown.
- `h1_graceful_shutdown_active_upload`: exercises graceful shutdown while a handler is blocked reading a stalled upload.
- `h1_immediate_mid_streaming_response`: verifies that a streaming response connection is torn down by Immediate shutdown.
- `h1_shutdown_during_request_body_read`: verifies Immediate shutdown aborts an in-progress body transfer.
- `h1_many_connections_then_shutdown`: verifies concurrent H1 connections are
  dropped promptly.
- `h1_repeated_start_stop`: checks for fd leaks across start/request/stop cycles.
- `h1_listener_close_while_active`: verifies the listener stops accepting after
  shutdown.
- `h2_immediate_shutdown_sleeping_handler`: verifies sleeping H2 handlers are
  interrupted by Immediate shutdown.
- `h2_graceful_shutdown_active_stream`: exercises H2 graceful shutdown with an open client stream.
- `h2_many_streams_then_shutdown`: verifies concurrent H2 streams are dropped
  promptly.
