# h2_frames red-probe findings

Run the probe family with:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h2_frames/run.exe
```

All findings are against `eta_http` / `eta_http_eio` H2C server using the
in-process adversarial harness in `http-testsuite/lib/`.

---

## 1. `data_after_rst_stream` — DATA on a reset stream kills the connection

- **Status:** FAIL
- **Classification:** likely Eta bug
- **Protocol/backend:** HTTP/2 (H2C) via `Eta_http_eio.H2.Server_connection.run_h2c`

### Expected behavior

After the client cancels stream 1 with `RST_STREAM`, a subsequent `DATA` frame
on stream 1 should be treated as a stream error (`RST_STREAM` with
`STREAM_CLOSED`) or, if the implementation chooses to treat it as a connection
error, as a `GOAWAY`. Either way, the unrelated `HEADERS` frame on stream 3
should still be processed and responded to.

### Actual behavior

The server sends `RST_STREAM` on stream 1 and then closes the TCP connection.
It does not send `GOAWAY`, and it never responds to the valid request on
stream 3.

### Minimized input / frame sequence

```text
CLIENT:  SETTINGS
CLIENT:  HEADERS    stream_id=1  end_stream=false  (opens stream 1)
CLIENT:  RST_STREAM stream_id=1  error_code=8       (CANCEL)
CLIENT:  DATA       stream_id=1  "x"                (invalid: stream closed)
CLIENT:  HEADERS    stream_id=3  end_stream=true    (valid new request)
CLIENT:  SHUTDOWN   send

SERVER:  SETTINGS
SERVER:  WINDOW_UPDATE stream_id=0
SERVER:  SETTINGS ACK
SERVER:  WINDOW_UPDATE stream_id=0
SERVER:  RST_STREAM stream_id=1
SERVER:  TCP close (no GOAWAY, no response for stream 3)
```

### Why this is likely an Eta bug

RFC 7540 §6.4 allows a receiver to treat frames received after `RST_STREAM` as
a connection error, but §5.4.1 requires that a connection error be signaled
with `GOAWAY` before closing. The server here closes without `GOAWAY`. Even if
the invalid `DATA` is handled as a stream error, the connection should remain
open for stream 3.

---

## 2. `headers_without_end_headers` — incomplete HEADERS closed without GOAWAY

- **Status:** POLICY_GAP
- **Classification:** likely Eta bug
- **Protocol/backend:** HTTP/2 (H2C) via `Eta_http_eio.H2.Server_connection.run_h2c`

### Expected behavior

A `HEADERS` frame without `END_HEADERS`, followed by EOF instead of a
`CONTINUATION` frame, is a protocol error. The server should send a `GOAWAY`
frame (typically `PROTOCOL_ERROR`) and then close the connection.

### Actual behavior

The server sends its connection preface (`SETTINGS`, `WINDOW_UPDATE`,
`SETTINGS ACK`) and then closes the TCP connection without sending `GOAWAY` or
`RST_STREAM`.

### Minimized input / frame sequence

```text
CLIENT:  SETTINGS
CLIENT:  HEADERS stream_id=1  end_headers=false  (expects CONTINUATION)
CLIENT:  SHUTDOWN send

SERVER:  SETTINGS
SERVER:  WINDOW_UPDATE stream_id=0
SERVER:  SETTINGS ACK
SERVER:  TCP close (no GOAWAY, no RST_STREAM)
```

### Why this is likely an Eta bug

RFC 7540 §5.4.1: "An endpoint that encounters a connection error SHOULD first
send a GOAWAY frame ... with the stream identifier of the last stream that it
successfully received from its peer." Closing on an incomplete header block
without signaling the error makes debugging and compliant error handling
impossible for peers.

---

## 3. `goaway_lower_last_stream` — GOAWAY with lower last-stream-id skips active stream

- **Status:** POLICY_GAP
- **Classification:** ambiguous policy gap
- **Protocol/backend:** HTTP/2 (H2C) via `Eta_http_eio.H2.Server_connection.run_h2c`

### Expected behavior

When the client sends `GOAWAY` with `last_stream_id=1`, streams with id <= 1
(stream 1) are considered "processed or in flight" and should be allowed to
complete. Streams with id > 1 (stream 3) should be rejected. The server should
therefore respond to stream 1 before closing.

### Actual behavior

The server echoes a `GOAWAY` and closes without responding to stream 1.

### Minimized input / frame sequence

```text
CLIENT:  SETTINGS
CLIENT:  HEADERS stream_id=1  end_stream=true
CLIENT:  HEADERS stream_id=3  end_stream=true
CLIENT:  GOAWAY  last_stream_id=1  error_code=0
CLIENT:  SHUTDOWN send

SERVER:  SETTINGS
SERVER:  WINDOW_UPDATE stream_id=0
SERVER:  SETTINGS ACK
SERVER:  GOAWAY  stream_id=0
SERVER:  TCP close (no response for stream 1)
```

### Why this is ambiguous

The RFC permits implementations to choose when to initiate graceful shutdown,
but it also says active streams should be processed. The observed behavior is
safe (no crash/hang) but may be overly aggressive: it forfeits a response for a
stream the peer explicitly declared as in-flight. Classified as a policy gap
pending an explicit Eta decision on whether streams opened before a received
`GOAWAY` must be completed.

---

## Probes that found nothing but are worth keeping

The following probes currently pass and are retained because they exercise
frame/state-machine edges that are easy to regress:

- `data_before_headers`
- `headers_after_end_stream`
- `continuation_without_headers`
- `headers_on_stream_zero`
- `headers_on_even_stream`
- `client_push_promise`
- `priority_ignored`
- `unknown_frame_ignored`
- `rst_stream_mid_response`
- `goaway_mid_stream`
- `settings_mid_stream`
- `ping_requires_ack`
- `window_update_before_headers`
- `continuation_fragmentation`
- `rst_stream_on_idle`
- `data_on_stream_zero`
- `settings_on_nonzero_stream`
- `ping_on_nonzero_stream`
- `continuation_wrong_stream`
