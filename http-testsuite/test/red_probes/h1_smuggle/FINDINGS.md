# h1_smuggle findings

Probes run against `eta_http_eio` H1 server with default and pipeline-friendly
configurations. All probes complete without crashing the runner; findings are
recorded as HANG/FAIL observations.

## 1. H1 pipelining hangs with multiple GET requests

- **probe:** `pipeline_get_get`
- **command:**
  ```sh
  nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h1_smuggle/run.exe
  ```
- **expected behavior:** Two `GET / HTTP/1.1` requests sent on one connection
  should produce two `200 OK` responses.
- **actual behavior:** The probe HANGs; no response bytes are received before
  the 2-second deadline. The server appears to deadlock or wait indefinitely.
- **protocol/backend:** HTTP/1.1 plain text, `Eta_http_eio.Server.start_h1_on_socket`
- **minimized input:**
  ```
  GET / HTTP/1.1\r\nHost: example.test\r\n\r\n
  GET / HTTP/1.1\r\nHost: example.test\r\n\r\n
  ```
- **classification:** likely Eta bug

## 2. H1 pipelining hangs with a bodied POST followed by a GET

- **probe:** `cl_only_pipeline`
- **command:** same as above
- **expected behavior:** `POST /echo Content-Length: 5` with body `hello`
  followed by `GET /` should produce two `200 OK` responses.
- **actual behavior:** The probe HANGs; no response bytes are received before
  the deadline.
- **protocol/backend:** HTTP/1.1 plain text
- **minimized input:**
  ```
  POST /echo HTTP/1.1\r\nHost: example.test\r\nContent-Length: 5\r\n\r\nhello
  GET / HTTP/1.1\r\nHost: example.test\r\n\r\n
  ```
- **classification:** likely Eta bug

## 3. H1 pipelining hangs with a Content-Length that is longer than the body

- **probe:** `cl_too_long`
- **command:** same as above
- **expected behavior:** `POST /echo Content-Length: 3` with body `hello`
  followed by `GET /` should consume exactly `hel` as the body, then process
  the leftover `loGET / HTTP/1.1...` as a second request (expected 404).
- **actual behavior:** The probe HANGs; only the first response is partially
  processed or no bytes are returned before the deadline.
- **protocol/backend:** HTTP/1.1 plain text, pipeline policy `Drain_up_to`
- **minimized input:**
  ```
  POST /echo HTTP/1.1\r\nHost: example.test\r\nContent-Length: 3\r\n\r\nhello
  GET / HTTP/1.1\r\nHost: example.test\r\n\r\n
  ```
- **classification:** likely Eta bug

## 4. Chunked request pipelining drops the second request

- **probe:** `chunked_pipeline`
- **command:** same as above
- **expected behavior:** A chunked `POST /echo` with body `hello` followed by
  `GET /` should produce two `200 OK` responses.
- **actual behavior:** Only one `200 OK` response is returned. The second
  request is silently dropped or the connection is kept open without processing
  it.
- **protocol/backend:** HTTP/1.1 plain text, pipeline policy `Drain_up_to`
- **minimized input:**
  ```
  POST /echo HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n
  5\r\nhello\r\n
  0\r\n\r\n
  GET / HTTP/1.1\r\nHost: example.test\r\n\r\n
  ```
- **classification:** likely Eta bug

## 5. Content-Length shorter than the body consumes bytes from the next request

- **probe:** `cl_too_short`
- **command:** same as above
- **expected behavior:** `POST /echo Content-Length: 10` with only `hello`
  before the next request should either time out/close without processing the
  smuggled request, or reject the first request because the body is incomplete.
- **actual behavior:** The server reads the missing body bytes from the
  smuggled request (`GET /`), echoes `helloGET /` as the POST body, then
  returns `400` for the corrupted second request.
- **protocol/backend:** HTTP/1.1 plain text, pipeline policy `Drain_up_to`
- **minimized input:**
  ```
  POST /echo HTTP/1.1\r\nHost: example.test\r\nContent-Length: 10\r\n\r\nhello
  GET / HTTP/1.1\r\nHost: example.test\r\n\r\n
  ```
- **classification:** ambiguous policy gap
- **note:** This is the expected consequence of trusting a wrong Content-Length,
  but it demonstrates that a front-end smuggling attack can corrupt the
  following request. A stricter policy could close the connection as soon as
  the body framing becomes inconsistent.

## 6. Bare CR request line waits for timeout instead of rejecting

- **probe:** `bare_cr_request_line`
- **command:** same as above
- **expected behavior:** `GET / HTTP/1.1\r` (bare CR, no LF) should be rejected
  immediately as malformed.
- **actual behavior:** The probe HANGs until the deadline; the server waits for
  the missing LF rather than treating a bare CR as an error.
- **protocol/backend:** HTTP/1.1 plain text
- **minimized input:**
  ```
  GET / HTTP/1.1\r
  ```
- **classification:** ambiguous policy gap
- **note:** RFC 7230 requires CRLF line endings. Waiting for a timeout is safe
  but slower than an immediate 400.
