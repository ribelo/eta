# tls_frag findings

## Summary

The `tls_frag` probe family found one real bug class in `eta_http_eio`:
request bodies (H1 fixed-length bodies and H2 DATA frames) hang the server
connection when the body bytes are delivered as one byte per TLS record (or,
in the H2C isolation probe, one byte per plain TCP write). The hang reproduces
on both the default Eio backend and the posix backend.

All shutdown-during-handshake/headers/DATA/trailer probes and the slow-preface
probe completed safely within the deadline.

## Finding 1: Byte-fragmented request bodies hang server body drain

- **Probe names:**
  - `h1_body_byte_records`
  - `h1_body_ignored_byte_records`
  - `h2_data_payload_byte`
  - `h2_data_frame_byte`
  - `h2_tiny_writes`
  - `h2c_data_payload_byte`
- **Classification:** likely Eta bug
- **Protocol/backend involved:** HTTPS/H1, HTTPS/H2, H2C; both default and
  `EIO_BACKEND=posix`
- **Exact command to reproduce:**
  ```sh
  nix --option eval-cache false develop -c dune exec \
    http-testsuite/test/red_probes/tls_frag/run.exe
  EIO_BACKEND=posix nix --option eval-cache false develop -c dune exec \
    http-testsuite/test/red_probes/tls_frag/run.exe
  ```
- **Expected behavior:** The server should accept the request body one byte at
  a time and respond (or, for the body-ignored H1 probe, send the response and
  drain/discard the tiny body) within a small fraction of a second.
- **Actual behavior:** Each affected probe hits the 5-second deadline. The
  server does not crash or leak an exception; it simply stops making progress
  on the connection.
- **Minimized input / frame sequence:**
  - H1 over TLS: send
    `POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\n`
    in one write, then send the five body bytes `h`, `e`, `l`, `l`, `o` as
    five separate one-byte TLS writes. The same hang occurs with
    `POST /healthz` (handler does not read the body), showing the problem is
    in body drain, not in the application handler.
  - H2 over TLS: after the client preface and SETTINGS exchange, send HEADERS
    (`:method POST`, no `END_STREAM`), then send a DATA frame header declaring
    5 bytes, then send the five payload bytes as separate one-byte TLS writes,
    then a final empty DATA frame with `END_STREAM`. The same hang occurs when
    the whole DATA frame (header + payload) is sent one byte at a time, and
    when the entire H2 request is sent one byte at a time.
  - H2C isolation: the identical DATA payload fragmentation over cleartext
    H2C also hangs, so the bug is not specific to TLS framing.

## Other probes

The following probes did not find a bug or policy gap; they are worth keeping
as regression/protection probes:

- `h1_byte_records` — H1 request line/headers sent one byte per TLS record:
  PASS.
- `h2_byte_frames` — H2 preface/SETTINGS/HEADERS sent one byte per TLS record:
  PASS.
- `h2_slow_preface` — ALPN `h2` negotiated, then the 24-byte preface is sent
  slowly (100ms per byte): PASS.
- `shutdown_during_handshake` — plaintext bytes sent to the TLS port and
  half-closed: PASS.
- `shutdown_during_headers` — TLS handshake completed, then a partial H2
  HEADERS frame is sent and TLS is closed: PASS.
- `shutdown_during_data` — TLS handshake completed, then a partial H2 DATA
  frame is sent and TLS is closed: PASS.
- `shutdown_during_trailers` — TLS handshake completed, then a partial H1
  chunked trailer section is sent and TLS is closed: PASS.
- `alpn_h2_only` — basic ALPN `h2` negotiation sanity check: PASS.
