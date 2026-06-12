# handler_fail red-probe findings

Run the suite with:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/handler_fail/run.exe
```

## 1. h2_stream_read_raise_after_partial

- **Probe name:** `h2_stream_read_raise_after_partial`
- **Protocol / backend:** HTTP/2 cleartext (`eta_http_eio` H2C server)
- **Classification:** likely Eta bug
- **Expected behavior:** When the response body `read` function emits one DATA
  chunk and then raises, the server should either reset the stream with
  `RST_STREAM` or replace the response with a default error before any DATA is
  flushed. The client should observe `HEADERS` + partial `DATA` + `RST_STREAM`.
- **Actual behavior:** The server sends the `HEADERS` frame and the partial
  `DATA` chunk, then closes the connection without ever sending `RST_STREAM`.
  The probe records `headers=true rst=false` and 79 bytes received.
  Probe output:
  ```
  FAIL headers without rst_stream: partial body then raise (len=79 headers=true rst=false)
  ```
- **Minimized repro / frame sequence:**
  - Client sends H2 connection preface, `SETTINGS`, and a `HEADERS` frame on
    stream 1 (`:method GET`, `:scheme http`, `:path /`, `:authority
    example.test`).
  - Server handler returns a `Response.Body.stream` with `length = 10`.
  - First `read` returns `Some "abc"`; second `read` raises
    `Failure("stream read raised after partial body")`.
  - Server replies with `HEADERS` (status 200, `content-length: 10`) and a
    3-byte `DATA` frame, then stops sending frames.

## 2. h2_trailers_construction_raise

- **Probe name:** `h2_trailers_construction_raise`
- **Protocol / backend:** HTTP/2 cleartext (`eta_http_eio` H2C server)
- **Classification:** likely Eta bug
- **Expected behavior:** When the response `trailers` thunk raises after the
  body stream has returned `None`, the server should reset the stream with
  `RST_STREAM` (or otherwise fail cleanly) rather than leaving the stream open.
- **Actual behavior:** The server sends `HEADERS` (status 200) and the full
  `DATA` frame for "hello", then closes the connection without sending
  `RST_STREAM`. The probe records `headers=true rst=false` and 76 bytes
  received.
  Probe output:
  ```
  FAIL headers without rst_stream: trailers raise (len=76 headers=true rst=false)
  ```
- **Minimized repro / frame sequence:**
  - Client sends H2 preface, `SETTINGS`, and a `HEADERS` frame on stream 1.
  - Server handler returns a streaming response whose `read` yields
    `Some "hello"` then `None`, and whose `trailers` thunk raises
    `Failure("trailers construction raised")`.
  - Server replies with `HEADERS` and a 5-byte `DATA` frame, then stops
    sending frames.

## 3. h2_cancellation_during_response

- **Probe name:** `h2_cancellation_during_response`
- **Protocol / backend:** HTTP/2 cleartext (`eta_http_eio` H2C server)
- **Classification:** confirmed Eta bug
- **Expected behavior:** Cancellation of the fiber producing the response body
  (via `Eio.Cancel.cancel` on its own context) should be caught by the server
  and converted into a stream reset (`RST_STREAM`) or a clean connection
  shutdown. The client should not see an unhandled exception.
- **Actual behavior:** The unhandled `Eio.Cancel.Cancelled` exception
  propagates out of the H2 server connection, causing the server fiber to
  crash. The probe reports:
  ```
  CRASH Cancelled: Cancelled: Failure("probe cancellation during response")
  ```
  No response frames are received by the client.
- **Minimized repro:**
  - Client sends H2 preface, `SETTINGS`, and a `HEADERS` frame on stream 1.
  - Server handler returns a streaming response whose `read` function cancels
    its own `Eio.Cancel` context and checks it, raising `Cancelled`.
  - The exception is not contained inside the stream/connection lifecycle.

## Probes that did not find issues (worth keeping)

- `h1_handler_raise_before_effect` — handler raises before returning an effect;
  server returns a clean HTTP/1.1 500 and closes.
- `h1_response_body_thunk_raise` — response body thunk raises immediately;
  server recovers with HTTP/1.1 500.
- `h1_stream_read_raise_after_partial` — stream read raises after emitting a
  partial chunk; server recovers with HTTP/1.1 500.
- `h1_trailers_construction_raise` — trailers thunk raises; server recovers
  with HTTP/1.1 500.
- `h1_cancellation_during_response` — self-cancellation during response body
  production is converted to HTTP/1.1 500.
- `h2_handler_raise_before_effect` — handler raises before returning an effect;
  server returns H2 HEADERS with status 500.
- `h2_response_body_thunk_raise` — response body thunk raises before any DATA;
  server sends HEADERS + RST_STREAM.
