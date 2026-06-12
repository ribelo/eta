# h2_flow findings

All probes were run with:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h2_flow/run.exe
```

All five probes exceeded their deadlines and recorded `HANG`. The server did not
send `GOAWAY`, `RST_STREAM`, or close the connection within the probe deadline.
This suggests `eta_http_eio`'s H2 owner loop can become pinned behind stalled
outbound writes, with no effective shorter bound for flow-control-blocked
responses.

---

## 1. h2_flow_tiny_initial_window

- **Classification:** ambiguous policy gap
- **Command:**
  ```sh
  nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h2_flow/run.exe
  ```
- **Expected behavior:** The server should either serve the response under the
  tiny initial window (HEADERS + 1 byte, then wait for `WINDOW_UPDATE`) or close
  the stream/connection within a reasonable time when no window is granted.
- **Actual behavior:** The server accepts the stream and then hangs for the full
  3 s probe deadline.
- **Protocol/backend:** H2C, `Eta_http_eio.H2.Server_connection`
- **Minimized input:**
  ```
  preface
  SETTINGS(INITIAL_WINDOW_SIZE=1)
  HEADERS(stream_id=1, END_STREAM)
  (no WINDOW_UPDATE sent)
  ```
- **Notes:** A SETTINGS_INITIAL_WINDOW_SIZE of 1 is legal per RFC 7540. The
  absence of any quicker outbound stall timeout makes this a DoS-relevant policy
  gap rather than a clear protocol bug.

---

## 2. h2_flow_withheld_window_update

- **Classification:** ambiguous policy gap
- **Command:** (same executable)
- **Expected behavior:** After the server sends its initial window of response
  data and exhausts the stream/connection flow-control window, it should time
  out and close the stream or connection.
- **Actual behavior:** The server sends some DATA frames, then hangs until the
  3 s probe deadline.
- **Protocol/backend:** H2C, `Eta_http_eio.H2.Server_connection`
- **Minimized input:**
  ```
  preface
  SETTINGS
  HEADERS(stream_id=1, END_STREAM)
  (server DATA consumed but no WINDOW_UPDATE ever sent)
  ```
- **Notes:** `response_write_timeout` is configured to 30 s by default, but it
  does not appear to bound the time spent waiting for a flow-control window.

---

## 3. h2_flow_window_update_overflow

- **Classification:** likely Eta bug
- **Command:** (same executable)
- **Expected behavior:** A `WINDOW_UPDATE` that would push the flow-control
  window above `2^31-1` is a protocol error; the server should emit a
  `GOAWAY` with `FLOW_CONTROL_ERROR` (error code 3) or reset the stream.
- **Actual behavior:** The server hangs for the full 3 s probe deadline instead
  of rejecting the overflow.
- **Protocol/backend:** H2C, `Eta_http_eio.H2.Server_connection`
- **Minimized input:**
  ```
  preface
  SETTINGS
  HEADERS(stream_id=1, END_STREAM)
  WINDOW_UPDATE(stream_id=1, increment=0x7FFFFFFF)
  ```
- **Notes:** The overflow should be detectable immediately on ingress. The hang
  suggests the owner/command loop is not processing incoming control frames
  while outbound writes are stalled.

---

## 4. h2_flow_slow_client_read

- **Classification:** ambiguous policy gap
- **Command:** (same executable)
- **Expected behavior:** A pathologically slow peer that grants one byte of
  window at a time should be disconnected after a minimum-throughput or stall
  timeout.
- **Actual behavior:** The server continues to dribble data one byte per
  `WINDOW_UPDATE` until the 3 s probe deadline.
- **Protocol/backend:** H2C, `Eta_http_eio.H2.Server_connection`
- **Minimized input:**
  ```
  preface
  SETTINGS
  HEADERS(stream_id=1, END_STREAM)
  loop: read one DATA frame, sleep 0.5 s, send WINDOW_UPDATE(stream_id=1, 1)
  ```
- **Notes:** There is no evidence of a minimum throughput or slow-reader
  timeout. This is a classic slow-read DoS vector.

---

## 5. h2_flow_concurrent_stalled_streams

- **Classification:** likely Eta bug
- **Command:** (same executable)
- **Expected behavior:** Opening many streams near `max_concurrent_streams`
  (120 streams vs. default 128) and withholding `WINDOW_UPDATE` should trigger
  either stream resets or a connection-level timeout, not unbounded resource
  retention.
- **Actual behavior:** The server accepts all 120 streams and hangs for the full
  5 s probe deadline.
- **Protocol/backend:** H2C, `Eta_http_eio.H2.Server_connection`
- **Minimized input:**
  ```
  preface
  SETTINGS
  for i = 1 .. 120:
      HEADERS(stream_id=(2*i-1), END_STREAM)
  (no WINDOW_UPDATE sent)
  ```
- **Notes:** The server accumulates a large number of blocked response writers
  without an observable fast fail-safe. Combined with the lack of a short
  outbound stall timeout, this makes concurrent slow-reader attacks practical.

---

## Summary

| Probe | Status | Classification |
|-------|--------|----------------|
| h2_flow_tiny_initial_window | HANG | ambiguous policy gap |
| h2_flow_withheld_window_update | HANG | ambiguous policy gap |
| h2_flow_window_update_overflow | HANG | likely Eta bug |
| h2_flow_slow_client_read | HANG | ambiguous policy gap |
| h2_flow_concurrent_stalled_streams | HANG | likely Eta bug |

None of the probes were fixed; they are recorded as findings for future
hardening of `eta_http_eio` H2 flow-control handling.
