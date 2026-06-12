# ws_malicious_server findings

WebSocket adversarial server probes against `eta_http_eio.Ws.Client`.

Run:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/ws_malicious_server/run.exe
```

## Non-PASS probes

### `ping_flood`

- **Classification:** likely Eta bug
- **Command:**
  ```sh
  nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/ws_malicious_server/run.exe
  ```
- **Expected behavior:** The client should either apply a ping rate limit or,
  at minimum, remain responsive to Eta's own timeout/cancellation so that a
  read on `Ws.Client.incoming` returns within the deadline.
- **Actual behavior:** The server sends 10,000 ping frames. The client's reader
  daemon replies to each ping synchronously (`send_frame`) without yielding.
  The inbound stream never makes progress and the Eta `timeout_as` deadline
  does not fire promptly; the outer Eio timeout observes a hang.
- **Protocol/backend:** WebSocket / `eta_http_eio.Ws.Client`
- **Minimized input:** After a valid upgrade handshake, send `ping` frames
  (`0x89 0x01 'x'`) in a tight loop.
- **Note:** This is a DoS vector: a malicious server can keep the client busy
  in a synchronous pong loop, preventing user reads and cancellation.

### `invalid_upgrade_http10`

- **Classification:** ambiguous policy gap
- **Command:**
  ```sh
  nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/ws_malicious_server/run.exe
  ```
- **Expected behavior:** RFC 6455 requires the WebSocket handshake to use
  HTTP/1.1. An `HTTP/1.0 101 Switching Protocols` response should be rejected
  as a protocol error.
- **Actual behavior:** The client accepts the `HTTP/1.0` response and waits for
  WebSocket frames, hanging until the deadline.
- **Protocol/backend:** WebSocket / `eta_http_eio.Ws.Client`
- **Minimized input:**
  ```
  HTTP/1.0 101 Switching Protocols\r\n
  Upgrade: websocket\r\n
  Connection: Upgrade\r\n
  Sec-WebSocket-Accept: <correct accept key>\r\n
  \r\n
  ```
- **Note:** Accepting HTTP/1.0 is non-compliant but may be intentional
  leniency. Documented as a policy gap rather than a hard failure.

## PASS probes worth keeping

These probes exercise edge cases not already covered elsewhere and currently
pass; they are worth keeping as regression / behavior witnesses:

- `fragmented_control_ping` / `fragmented_control_close` — control frames with
  `FIN=false` are rejected.
- `close_oversized_payload` / `close_one_byte_payload` — malformed close frame
  lengths are rejected.
- `close_invalid_code_999` / `close_reserved_code_1004` /
  `close_reserved_code_1005` / `close_reserved_code_1015` — invalid/ reserved
  close codes are rejected.
- `close_invalid_utf8_reason` — close reason UTF-8 is validated.
- `invalid_opcode_3` / `invalid_opcode_7` / `invalid_opcode_15` — reserved
  opcodes are rejected.
- `unmasked_server_text` — normal unmasked server text frame is delivered.
- `masked_server_text` — masked server frames are rejected.
- `interleaved_ping_during_fragment` / `interleaved_close_during_fragment` —
  control frames interleaved in fragmented data messages are handled correctly.
- `reserved_bits_rsv1` — reserved bits are rejected.
- `non_minimal_length` — non-minimal length encoding is rejected.
- `invalid_upgrade_missing_upgrade` / `invalid_upgrade_wrong_accept` /
  `invalid_upgrade_200_ok` — handshake validation works.
- `handshake_close_immediately` / `handshake_garbage_response` — abrupt
  handshake failures return typed errors.
- `huge_frame_declared_length` — frames larger than `max_frame_size` are
  rejected before payload allocation.
- `text_invalid_utf8` — text-frame payloads are validated as UTF-8.
- `empty_close_frame` — a close frame with no payload is treated as a normal
  close (code 1000).
- `ping_oversized_payload` — control frames with payload >125 bytes are
  rejected.
- `unsolicited_pong` — unsolicited pong frames are ignored and do not break
  the reader.
- `continuation_without_start` — continuation frames without an initial data
  frame are rejected.
