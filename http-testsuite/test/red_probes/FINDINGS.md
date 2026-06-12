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

## Current findings summary

| Probe | Family | Status | Classification |
|---|---|---|---|
| `stalled_body_not_blocking` | `h2_server_streams` | HANG | confirmed Eta bug |
| `empty_data_flood` | `h2_server_streams` | FAIL | confirmed Eta bug |
| `settings_flood_mid_stream` | `h2_server_streams` | FAIL | confirmed Eta bug |
| `pool_dead_keepalive_connection` | `h1_client_malicious` | FAIL | likely Eta bug |
| `bare_cr_request_line` | `h1_smuggle` | HANG | ambiguous policy gap |
| `goaway_lower_last_stream` | `h2_frames` | POLICY_GAP | ambiguous policy gap |
| `headers_without_end_headers` | `h2_frames` | POLICY_GAP | ambiguous policy gap |
| `cancellation_during_retry_delay` | `client_retry_idempotency` | FAIL | confirmed Eta bug |
| `retry_after_respects_total_timeout` | `client_retry_idempotency` | FAIL | confirmed Eta bug |
| `retry_after_date_format` | `client_retry_idempotency` | FAIL | confirmed Eta bug |
| `goaway_high_last_stream_id` | `h2_client_malicious` | FAIL | confirmed Eta bug |
| `h1_immediate_shutdown_sleeping_handler` | `server_lifecycle` | HANG | likely Eta bug |
| `h1_many_connections_then_shutdown` | `server_lifecycle` | HANG | likely Eta bug |
| `h2_immediate_shutdown_sleeping_handler` | `server_lifecycle` | HANG | likely Eta bug |
| `h2_many_streams_then_shutdown` | `server_lifecycle` | HANG | likely Eta bug |
| `h1_listener_close_while_active` | `server_lifecycle` | POLICY_GAP | ambiguous policy gap |
| `ping_flood` | `ws_malicious_server` | POLICY_GAP | likely Eta bug |
| `invalid_upgrade_http10` | `ws_malicious_server` | POLICY_GAP | ambiguous policy gap |

Per-family `FINDINGS.md` files contain the minimized repro, expected behavior,
actual behavior, and protocol/backend details for each finding.

## What changed since the first red-probe pass

The first pass findings were fixed in commit `f086b3768 fix: harden eta http
edge cases`. This second pass targets new surfaces and finds new bugs:

- **H2 server stream scheduling / limits**: a stalled request body blocks other
  streams; empty-DATA and SETTINGS limits are off-by-one or not enforced
  mid-connection.
- **H1 client pooling**: a dead `Connection: keep-alive` connection is reused
  within the health-check window and causes the next request to time out.
- **H2 client protocol**: `GOAWAY` with an impossibly high `last_stream_id` is
  accepted instead of rejected as a protocol error.
- **Client retry / idempotency**: total timeouts do not cancel retry delays;
  far-future `Retry-After` HTTP dates are accepted uncapped.
- **Server lifecycle**: `shutdown Immediate` returns without cancelling in-flight
  handler fibers, and the listening socket may remain open.
- **WebSocket client**: ping floods can synchronously block the read loop and
  delay cancellation/timeouts; an `HTTP/1.0 101` upgrade is accepted.

## Fixed findings from the first pass

The following original red findings now pass or have deterministic regression
coverage:

- H1 pipelining: two pipelined GETs, bodied POST + GET, chunked POST + GET,
  and `Content-Length` boundary cases complete without hanging.
- H1 handler failure/timeout: recovered handler errors return 500/503 and close
  the connection rather than reusing it for pipelined requests.
- H2 response failure handling: response body exceptions, trailer construction
  exceptions, and response-body cancellation produce stream resets instead of
  escaping or silently closing.
- H2 DATA after peer reset: late DATA on stream 1 is ignored as a closed-stream
  artifact and an unrelated valid stream 3 still receives a response.
- H2 flow-control stalls: the probes now configure a short response write
  timeout and observe bounded stream resets or flow-control errors.
- TLS/tiny-fragment delivery: H1/TLS, H2/TLS, and H2C byte-fragmented request
  bodies complete; the probes stop on response completion instead of waiting
  for keep-alive connection close.

## Green gates

Run after this red-probe pass:

- `nix --option eval-cache false develop -c dune runtest test/http --force`: 199 tests pass.
- `nix --option eval-cache false develop -c dune runtest test/http_eio --force`: 142 tests pass.
- `nix --option eval-cache false develop -c dune exec http-testsuite/test/cve_regress/run.exe`: PASS 27, FAIL 0, SKIP 0.
- `nix --option eval-cache false develop -c dune exec http-testsuite/test/interop/run.exe`: PASS 314, DIVERGENT 0, FAIL 0, SKIP 176.
- `nix --option eval-cache false develop -c dune build @red-probes`: completes.
