# h2_server_streams findings

Run:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h2_server_streams/run.exe
```

## Confirmed / likely Eta bugs

### `h2_streams_stalled_body_not_blocking` — HANG

- **Reproduce:** `dune exec http-testsuite/test/red_probes/h2_server_streams/run.exe`
- **Protocol/backend:** H2C / `eta_http_eio.H2.Server_connection`
- **Minimized input:**
  1. Client preface + SETTINGS.
  2. `HEADERS` on stream 1 (`POST`, `END_STREAM=false`).
  3. `HEADERS` + `DATA` (with `END_STREAM=true`) on streams 3, 5, 7, 9, 11, 13, 15, 17, 19.
- **Expected:** The nine complete streams are processed and return 200 responses even though stream 1's body never finishes.
- **Actual:** The server sends no responses at all within the 5-second deadline. The connection remains open and the probe records `only 0/9 responses, connection still open`.
- **Classification:** confirmed Eta bug — a single stalled request body blocks scheduling/dispatch of all other concurrent streams.

### `h2_streams_empty_data_flood` — FAIL

- **Reproduce:** `dune exec http-testsuite/test/red_probes/h2_server_streams/run.exe`
- **Protocol/backend:** H2C / `eta_http_eio.H2.Server_connection`
- **Minimized input:**
  1. Client preface + SETTINGS.
  2. `HEADERS` on stream 1 (`POST`, `END_STREAM=false`).
  3. 101 empty `DATA` frames (`length=0`, `END_STREAM=false`) spread across streams 1, 3, 5, 7, 9.
  4. `HEADERS` on stream 11 (`GET`, `END_STREAM=true`).
- **Expected:** The default `max_empty_data_frames_per_connection` is 100, so the 101st empty DATA frame should trigger a connection error (GOAWAY or RST_STREAM) and the connection should close.
- **Actual:** The server accepts all 101 empty DATA frames and keeps the connection open. Only the initial handshake WINDOW_UPDATE and SETTINGS ACK are observed (22 bytes); no error frame is returned.
- **Classification:** confirmed Eta bug — the per-connection empty-DATA frame limit is not enforced across multiple streams.

### `h2_streams_settings_flood_mid_stream` — FAIL

- **Reproduce:** `dune exec http-testsuite/test/red_probes/h2_server_streams/run.exe`
- **Protocol/backend:** H2C / `eta_http_eio.H2.Server_connection`
- **Minimized input:**
  1. Client preface + SETTINGS.
  2. `HEADERS` on stream 1 (`POST`, `END_STREAM=false`).
  3. 11 additional `SETTINGS` frames (each carrying `MAX_CONCURRENT_STREAMS=10`).
  4. `HEADERS` on stream 3 (`GET`, `END_STREAM=true`).
- **Expected:** The default `max_settings_per_connection` is 10. With the initial client SETTINGS counted, the 11th SETTINGS frame should trigger a connection error (GOAWAY) and the connection should close.
- **Actual:** The server accepts all 12 SETTINGS frames and keeps the connection open. Only the handshake WINDOW_UPDATE and SETTINGS ACK are observed (22 bytes); no error frame is returned.
- **Classification:** confirmed Eta bug — the per-connection SETTINGS churn limit is not enforced while streams are active.

## Probes that pass and are worth keeping

- `h2_streams_data_interleaved` — interleaved DATA across 20 concurrent POST streams.
- `h2_streams_rst_during_bodies` — RST_STREAM on one partial body while other streams complete.
- `h2_streams_settings_lower_max_concurrent` — peer SETTINGS lowering `MAX_CONCURRENT_STREAMS` does not disrupt already-open client streams.
- `h2_streams_priority_self_dependency` — PRIORITY frame that makes a stream depend on itself is rejected.
- `h2_streams_tiny_data_chunks` — 1-byte DATA chunks on 40 concurrent streams.
- `h2_streams_headers_flood_no_data` — 80 concurrent HEADERS with `END_STREAM=true`.
- `h2_streams_unread_bodies_interleaved` — handler returns without reading interleaved request bodies.
- `h2_streams_priority_on_stream_zero` — PRIORITY on stream 0 is rejected with GOAWAY.
