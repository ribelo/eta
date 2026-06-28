# ws_malicious_server findings

WebSocket adversarial server probes against `eta_http_eio.Ws.Client`.

Run:

```sh
nix develop -c dune exec http-testsuite/test/red_probes/ws_malicious_server/run.exe
```

## Current status

All probes in this family pass.

Resolved findings:

- `ping_flood` now returns a typed `Protocol "WebSocket ping flood"` after the
  configured consecutive-ping limit is exceeded.
- `invalid_upgrade_http10` now returns a typed protocol error because WebSocket
  upgrade responses must use HTTP/1.1.

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
  `invalid_upgrade_200_ok` / `invalid_upgrade_http10` — handshake validation
  works.
- `handshake_close_immediately` / `handshake_garbage_response` — abrupt
  handshake failures return typed errors.
- `huge_frame_declared_length` — frames larger than `max_frame_size` are
  rejected before payload allocation.
- `text_invalid_utf8` — text-frame payloads are validated as UTF-8.
- `empty_close_frame` — a close frame with no payload is treated as a normal
  close (code 1000).
- `ping_oversized_payload` — control frames with payload >125 bytes are
  rejected.
- `ping_flood` — consecutive peer pings are bounded and fail with a typed
  protocol error.
- `unsolicited_pong` — unsolicited pong frames are ignored and do not break
  the reader.
- `continuation_without_start` — continuation frames without an initial data
  frame are rejected.
