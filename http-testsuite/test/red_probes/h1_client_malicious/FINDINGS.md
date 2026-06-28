# h1_client_malicious findings

Build and run the family:

```sh
nix develop -c dune build http-testsuite/test/red_probes/h1_client_malicious
nix develop -c dune exec http-testsuite/test/red_probes/h1_client_malicious/run.exe
```

The runner always exits 0, even when probes fail or a probe hangs; each
individual probe is capped at 30 seconds by a watchdog.

## Current status

All bug-classified probes in this family pass.

Resolved finding:

- `pool_dead_keepalive_connection`: the default H1 pool health check now probes
  idle reusable connections before checkout, so a server-closed keep-alive
  connection is discarded and the next request opens a fresh connection.

## Policy gaps / ambiguous behavior

### `h10_keepalive_stays_open` — HTTP/1.0 keep-alive with no Content-Length hangs until the request deadline

- **Probe:** `h10_keepalive_stays_open`
- **Command:**
  ```sh
  nix develop -c dune exec http-testsuite/test/red_probes/h1_client_malicious/run.exe | grep h10_keepalive_stays_open
  ```
- **Expected:** HTTP/1.0 keep-alive requires an explicit body length. A
  response that omits both `Content-Length` and `Transfer-Encoding` but claims
  `Connection: keep-alive` could be rejected immediately as unframeable.
- **Actual:** The client treats it as close-delimited and blocks reading until
  the request-level deadline fires. The probe therefore records `PASS` (it
  does not hang forever), but the only safe behavior is a timeout.
- **Protocol/backend:** HTTP/1.0, `eta_http_eio` H1 client.
- **Minimized server response:**
  ```text
  HTTP/1.0 200 OK\r\n
  Connection: keep-alive\r\n\r\n
  hello
  ```
  with the socket left open.
- **Classification:** ambiguous policy gap — the client is technically RFC
  compliant (reads until EOF), but a stricter implementation could surface a
  typed framing error instead of waiting for the deadline.

### `duplicate_transfer_encoding_chunked` — duplicate identical `Transfer-Encoding: chunked` headers are rejected

- **Probe:** `duplicate_transfer_encoding_chunked`
- **Command:**
  ```sh
  nix develop -c dune exec http-testsuite/test/red_probes/h1_client_malicious/run.exe | grep duplicate_transfer_encoding_chunked
  ```
- **Expected:** RFC 7230 permits multiple `Transfer-Encoding` headers that are
  semantically combined; two identical `chunked` values should be accepted.
- **Actual:** Eta's client validates transfer-coding tokens as an ordered list
  and rejects any list other than `[]` or `["chunked"]`, so the response is
  rejected with `Connection_protocol_violation { kind = "transfer_encoding" }`.
- **Protocol/backend:** HTTP/1.1, `eta_http_eio` H1 client response parser.
- **Minimized server response:**
  ```text
  HTTP/1.1 200 OK\r\n
  Transfer-Encoding: chunked\r\n
  Transfer-Encoding: chunked\r\n\r\n
  5\r\nhello\r\n0\r\n\r\n
  ```
- **Classification:** ambiguous policy gap — the rejection is safe (no
  smuggling), but stricter than RFC 7230.

## Probes that pass and are worth keeping

The following probes do not find new bugs, but they cover client-side edge
 cases that are not exercised by the existing mock-based H1 client tests or by
 the server-focused red-probe families:

- `cl_te_response` — response with both `Content-Length` and
  `Transfer-Encoding: chunked` is decoded using chunked framing.
- `conflicting_content_length` — differing duplicate `Content-Length` headers
  are rejected.
- `duplicate_same_content_length` — identical duplicate `Content-Length`
  headers are accepted.
- `oversized_response_headers` — response header section larger than 32 KiB is
  rejected.
- `oversized_status_line` / `bare_cr_header` — malformed response start lines
  and header values are rejected.
- `invalid_chunk_size_hex` / `invalid_chunk_size_overflow` — malformed chunk
  size lines are rejected with a typed decode error.
- `chunk_size_line_no_crlf` — partial chunk size line is handled without
  hanging (returns a connection-closed error when the server closes).
- `infinite_chunked_response` / `slow_response_headers` — slow/infinite
  responses are bounded by the request timeout.
- `h10_keepalive_close_after_body` — HTTP/1.0 close-delimited response that
  closes the socket completes cleanly.
- `forbidden_trailer_content_length` — forbidden `Content-Length` trailer in a
  chunked response is rejected.
- `pool_clean_reuse` — two clean fixed-length responses reuse one pooled
  connection.
- `pool_leftover_after_fixed_body` / `pool_leftover_after_chunked_body` —
  leftover bytes after a complete body force the pool to open a new
  connection (`opened=2`).
- `pool_recovery_after_parse_error` / `pool_recovery_after_chunked_error` —
  after a response parse/decode error, the second request succeeds on a fresh
  connection.
- `pool_h10_keepalive_reuse` — HTTP/1.0 keep-alive with explicit
  `Content-Length` reuses the pooled connection.
