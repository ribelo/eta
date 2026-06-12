# Red Probes Aggregate Findings

The opt-in red probes under `http-testsuite/test/red_probes/` are adversarial
diagnostics. They are not part of normal `dune runtest`.

Run all families:

```sh
nix --option eval-cache false develop -c dune build @red-probes
```

Run individual families:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h1_smuggle/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h1_pipeline/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h1_client_malicious/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h2_frames/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h2_flow/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h2_client_malicious/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h2_server_streams/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/tls_frag/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/handler_fail/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/ws_malicious_server/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/client_retry_idempotency/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/server_lifecycle/run.exe
```

## Current non-PASS findings

| Probe | Family | Status | Classification |
|---|---|---|---|
| `bare_cr_request_line` | `h1_smuggle` | HANG | policy gap |
| `headers_without_end_headers` | `h2_frames` | POLICY_GAP | policy gap |
| `goaway_lower_last_stream` | `h2_frames` | POLICY_GAP | policy gap |

Additional safe-but-strict policy notes are documented in
`h1_client_malicious/FINDINGS.md`:

- `h10_keepalive_stays_open` completes through request timeout rather than an
  immediate unframeable-response error.
- `duplicate_transfer_encoding_chunked` is rejected even though duplicate
  identical `Transfer-Encoding: chunked` headers can be interpreted as
  equivalent to one header.

## Fixed second-pass findings

The swarm-generated second pass produced valid bugs and a few invalid
expectations. The following bug-classified probes now pass:

- `stalled_body_not_blocking`, `empty_data_flood`,
  `settings_flood_mid_stream` in `h2_server_streams`.
- `pool_dead_keepalive_connection` in `h1_client_malicious`.
- `cancellation_during_retry_delay`, `retry_after_respects_total_timeout`,
  `retry_after_date_format` in `client_retry_idempotency`.
- `h1_immediate_shutdown_sleeping_handler`,
  `h1_many_connections_then_shutdown`,
  `h2_immediate_shutdown_sleeping_handler`,
  `h2_many_streams_then_shutdown`,
  `h1_listener_close_while_active` in `server_lifecycle`.
- `ping_flood` and `invalid_upgrade_http10` in `ws_malicious_server`.
- `shutdown_during_headers` in `tls_frag`.

`goaway_high_last_stream_id` in `h2_client_malicious` was reclassified: a clean
GOAWAY whose `last_stream_id` is higher than the active stream does not fail the
stream by itself. The probe is retained as timeout regression coverage.

## Fixed first-pass findings

The first red-probe pass remains green:

- H1 pipelining and request-body boundary cases complete without hanging.
- H1 handler failures and timeouts return bounded error responses and close
  unsafe connections.
- H2 response body, trailer, and cancellation failures reset the affected
  stream instead of escaping the server fiber.
- H2 late DATA after peer reset does not poison unrelated streams.
- H2 flow-control stalls are bounded by response write timeouts.
- H1/TLS, H2/TLS, and H2C byte-fragmented request bodies complete.

## Verification status

Verified after cleanup and fixes:

- `nix --option eval-cache false develop -c dune build @red-probes`
- `nix --option eval-cache false develop -c dune runtest test/http --force`
- `nix --option eval-cache false develop -c dune runtest test/http_eio --force`
- `nix --option eval-cache false develop -c dune exec http-testsuite/test/cve_regress/run.exe`
- `nix --option eval-cache false develop -c dune exec http-testsuite/test/interop/run.exe`
- `nix --option eval-cache false develop -c dune build eta_http.install eta_http_eio.install`
- `nix --option eval-cache false develop -c bash bench/run.sh --quick`

Per-family `FINDINGS.md` files contain the minimized repros, expected behavior,
observed behavior, and protocol/backend details.
