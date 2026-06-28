# h2_flow Findings

Run:

```sh
nix develop -c dune exec http-testsuite/test/red_probes/h2_flow/run.exe
```

## Current Status

All probes pass. The family now configures a short `response_write_timeout`
inside the probe harness so flow-control stalls are tested deterministically
instead of waiting for Eta's production default timeout.

Latest observed outcomes:

- `h2_flow_tiny_initial_window`: PASS via bounded stream reset.
- `h2_flow_withheld_window_update`: PASS via bounded stream reset after the
  response flow-control window is exhausted.
- `h2_flow_window_update_overflow`: PASS via `FLOW_CONTROL_ERROR` stream reset.
- `h2_flow_slow_client_read`: PASS via bounded stream reset with a one-byte
  advertised window.
- `h2_flow_concurrent_stalled_streams`: PASS via bounded stream resets.

## Notes

This family verifies that Eta can bound pathological H2 response stalls when a
short response-write timeout is configured. It does not assert that the default
30 second production timeout is the right operational value for every public
edge deployment.
