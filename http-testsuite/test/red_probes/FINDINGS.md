# Red Probes Aggregate Findings

This file summarizes the findings from all opt-in red-probe families under
`http-testsuite/test/red_probes/`. These probes intentionally look for bugs and
policy gaps; they do not assert correctness.

Run the entire suite:

```sh
nix --option eval-cache false develop -c dune build @red-probes
```

Run individual families:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h1_smuggle/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h1_pipeline/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h2_frames/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h2_flow/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/tls_frag/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/handler_fail/run.exe
```

---

## Confirmed Eta bugs

### 1. `h1_pipeline.handler_exception_then_valid` — handler exception allows connection reuse

- **Family:** `h1_pipeline`
- **Command:** `dune exec http-testsuite/test/red_probes/h1_pipeline/run.exe`
- **Expected:** Handler exception returns 500 and closes the connection; pipelined second request is not processed.
- **Actual:** Server returns 500 for `/boom` then 200 for `/ok` on the same connection.
- **Protocol/backend:** HTTP/1.1 plain text, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h1_pipeline/run.ml`
- **Classification:** confirmed Eta bug

### 2. `handler_fail.h2_cancellation_during_response` — unhandled `Eio.Cancel.Cancelled` crashes H2 server fiber

- **Family:** `handler_fail`
- **Command:** `dune exec http-testsuite/test/red_probes/handler_fail/run.exe`
- **Expected:** Cancellation during response production is caught and converted to stream reset or clean error.
- **Actual:** `Eio.Cancel.Cancelled` escapes the H2 server connection and crashes the server fiber.
- **Protocol/backend:** HTTP/2 cleartext, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/handler_fail/run.ml`
- **Classification:** confirmed Eta bug

---

## Likely Eta bugs

### 3. `h1_smuggle.pipeline_get_get` — H1 pipelining hangs on two back-to-back GETs

- **Family:** `h1_smuggle`
- **Command:** `dune exec http-testsuite/test/red_probes/h1_smuggle/run.exe`
- **Expected:** Two pipelined `GET /` produce two `200 OK` responses.
- **Actual:** Probe hangs until deadline; no response bytes received.
- **Protocol/backend:** HTTP/1.1 plain text, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h1_smuggle/run.ml`

### 4. `h1_smuggle.cl_only_pipeline` — bodied POST + pipelined GET hangs

- **Family:** `h1_smuggle`
- **Expected:** `POST /echo Content-Length: 5` + `GET /` produces two responses.
- **Actual:** Probe hangs until deadline.
- **Protocol/backend:** HTTP/1.1 plain text, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h1_smuggle/run.ml`

### 5. `h1_smuggle.cl_too_long` — Content-Length longer than body hangs

- **Family:** `h1_smuggle`
- **Expected:** Server consumes declared body bytes and processes leftover as next request (or closes cleanly).
- **Actual:** Probe hangs until deadline.
- **Protocol/backend:** HTTP/1.1 plain text, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h1_smuggle/run.ml`

### 6. `h1_smuggle.chunked_pipeline` — chunked POST + pipelined GET drops second request

- **Family:** `h1_smuggle`
- **Expected:** Two responses.
- **Actual:** Only one `200 OK` returned; second request is silently dropped.
- **Protocol/backend:** HTTP/1.1 plain text, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h1_smuggle/run.ml`

### 7. `h1_pipeline.handler_timeout_then_valid` — handler_timeout not enforced

- **Family:** `h1_pipeline`
- **Command:** `dune exec http-testsuite/test/red_probes/h1_pipeline/run.exe`
- **Expected:** Handler running past configured timeout returns 503 and closes connection.
- **Actual:** Handler completes after 500 ms sleep, returns 200, and connection is reused.
- **Protocol/backend:** HTTP/1.1 plain text, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h1_pipeline/run.ml`

### 8. `h2_frames.data_after_rst_stream` — DATA on reset stream kills connection without GOAWAY

- **Family:** `h2_frames`
- **Command:** `dune exec http-testsuite/test/red_probes/h2_frames/run.exe`
- **Expected:** Stream error (`RST_STREAM`) or connection error with `GOAWAY`; unrelated stream 3 still served.
- **Actual:** Server sends `RST_STREAM` on stream 1 and closes TCP without `GOAWAY` or responding to stream 3.
- **Protocol/backend:** HTTP/2 cleartext, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h2_frames/run.ml`

### 9. `h2_frames.headers_without_end_headers` — incomplete HEADERS closed without GOAWAY

- **Family:** `h2_frames`
- **Command:** `dune exec http-testsuite/test/red_probes/h2_frames/run.exe`
- **Expected:** Protocol error signaled with `GOAWAY` before close.
- **Actual:** Server closes silently without `GOAWAY`/`RST_STREAM`.
- **Protocol/backend:** HTTP/2 cleartext, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h2_frames/run.ml`

### 10. `h2_flow.window_update_overflow` — WINDOW_UPDATE overflow hangs instead of error

- **Family:** `h2_flow`
- **Command:** `dune exec http-testsuite/test/red_probes/h2_flow/run.exe`
- **Expected:** `GOAWAY` with `FLOW_CONTROL_ERROR` or stream reset.
- **Actual:** Server hangs for full 3 s deadline.
- **Protocol/backend:** HTTP/2 cleartext, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h2_flow/run.ml`

### 11. `h2_flow.concurrent_stalled_streams` — many stalled streams hang without timeout

- **Family:** `h2_flow`
- **Command:** `dune exec http-testsuite/test/red_probes/h2_flow/run.exe`
- **Expected:** Streams reset or connection closed when flow-control windows are exhausted.
- **Actual:** 120 streams accepted and server hangs for 5 s deadline.
- **Protocol/backend:** HTTP/2 cleartext, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h2_flow/run.ml`

### 12. `tls_frag` family — byte-fragmented request bodies hang server

- **Family:** `tls_frag`
- **Command:** `dune exec http-testsuite/test/red_probes/tls_frag/run.exe`
- **Affected probes:** `h1_body_byte_records`, `h1_body_ignored_byte_records`, `h2_data_payload_byte`, `h2_data_frame_byte`, `h2_tiny_writes`, `h2c_data_payload_byte`
- **Expected:** Server accepts one-byte-at-a-time bodies and responds within milliseconds.
- **Actual:** Each affected probe hits the 5 s deadline. Reproduces over H1/TLS, H2/TLS, and H2C; on default and `EIO_BACKEND=posix`.
- **Protocol/backend:** HTTPS/H1, HTTPS/H2, H2C, both Eio backends
- **File:** `http-testsuite/test/red_probes/tls_frag/run.ml`

### 13. `handler_fail.h2_stream_read_raise_after_partial` — no RST_STREAM after partial DATA + raise

- **Family:** `handler_fail`
- **Command:** `dune exec http-testsuite/test/red_probes/handler_fail/run.exe`
- **Expected:** Server sends `HEADERS` + partial `DATA` + `RST_STREAM`.
- **Actual:** Server sends `HEADERS` + partial `DATA`, then closes without `RST_STREAM`.
- **Protocol/backend:** HTTP/2 cleartext, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/handler_fail/run.ml`

### 14. `handler_fail.h2_trailers_construction_raise` — no RST_STREAM after trailers raise

- **Family:** `handler_fail`
- **Command:** `dune exec http-testsuite/test/red_probes/handler_fail/run.exe`
- **Expected:** Server resets stream when trailers thunk raises.
- **Actual:** Server sends full response, then closes without `RST_STREAM`.
- **Protocol/backend:** HTTP/2 cleartext, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/handler_fail/run.ml`

---

## Ambiguous policy gaps

### 15. `h1_smuggle.cl_too_short` — wrong Content-Length consumes next request bytes

- **Family:** `h1_smuggle`
- **Command:** `dune exec http-testsuite/test/red_probes/h1_smuggle/run.exe`
- **Expected:** Server closes connection when body framing becomes inconsistent.
- **Actual:** Server reads missing body bytes from the next request, echoing `helloGET /` as POST body.
- **Protocol/backend:** HTTP/1.1 plain text, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h1_smuggle/run.ml`

### 16. `h1_smuggle.bare_cr_request_line` — bare CR waits for timeout instead of 400

- **Family:** `h1_smuggle`
- **Command:** `dune exec http-testsuite/test/red_probes/h1_smuggle/run.exe`
- **Expected:** Bare CR in request line rejected immediately as malformed.
- **Actual:** Server waits for missing LF until deadline.
- **Protocol/backend:** HTTP/1.1 plain text, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h1_smuggle/run.ml`

### 17. `h2_frames.goaway_lower_last_stream` — received GOAWAY forfeits active stream response

- **Family:** `h2_frames`
- **Command:** `dune exec http-testsuite/test/red_probes/h2_frames/run.exe`
- **Expected:** Server completes stream 1 (id <= peer's last_stream_id) before closing.
- **Actual:** Server echoes `GOAWAY` and closes without responding to stream 1.
- **Protocol/backend:** HTTP/2 cleartext, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h2_frames/run.ml`

### 18. `h2_flow.tiny_initial_window` — tiny SETTINGS_INITIAL_WINDOW_SIZE hangs

- **Family:** `h2_flow`
- **Command:** `dune exec http-testsuite/test/red_probes/h2_flow/run.exe`
- **Expected:** Server either serves under tiny window or closes within a bounded time.
- **Actual:** Server hangs for 3 s deadline.
- **Protocol/backend:** HTTP/2 cleartext, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h2_flow/run.ml`

### 19. `h2_flow.withheld_window_update` — stalled outbound write hangs

- **Family:** `h2_flow`
- **Command:** `dune exec http-testsuite/test/red_probes/h2_flow/run.exe`
- **Expected:** Flow-control-blocked response times out.
- **Actual:** Server hangs for 3 s deadline.
- **Protocol/backend:** HTTP/2 cleartext, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h2_flow/run.ml`

### 20. `h2_flow.slow_client_read` — pathologically slow reader hangs

- **Family:** `h2_flow`
- **Command:** `dune exec http-testsuite/test/red_probes/h2_flow/run.exe`
- **Expected:** Minimum-throughput or slow-reader timeout disconnects peer.
- **Actual:** Server dribbles data until 3 s deadline.
- **Protocol/backend:** HTTP/2 cleartext, `eta_http_eio`
- **File:** `http-testsuite/test/red_probes/h2_flow/run.ml`

---

## Green gates verified

After adding the red-probe suite, the existing green gates still pass:

- `dune runtest test/http`: 199 tests pass.
- `dune runtest test/http_eio`: 142 tests pass.
- `dune exec http-testsuite/test/cve_regress/run.exe`: PASS 27, FAIL 0, SKIP 0.
- `dune exec http-testsuite/test/interop/run.exe`: PASS 314, DIVERGENT 0, FAIL 0, SKIP 176.

The `@red-probes` alias is opt-in and does not run during `dune runtest`.
