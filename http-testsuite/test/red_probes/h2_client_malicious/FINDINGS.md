# h2_client_malicious findings

HTTP/2 client-side adversarial probes against `eta_http_eio.H2.Connection` and
`Eta_http_eio.Client.request_h2_on_connection`.  Each probe starts a malicious
in-process H2 server, connects the Eta H2 client over plain TCP, and records
whether the client returns a typed error, completes safely, or hangs past the
deadline.

## Run

```sh
nix develop -c dune exec http-testsuite/test/red_probes/h2_client_malicious/run.exe
```

## Reclassified generated probe

### `goaway_high_last_stream_id`

- **Command:**
  ```sh
  nix develop -c dune exec http-testsuite/test/red_probes/h2_client_malicious/run.exe
  ```
- **Expected behavior:**
  A clean GOAWAY frame whose `last_stream_id` is higher than the active stream
  does not fail that stream by itself. If the peer never sends response HEADERS,
  the request should end through the configured total-request timeout.
- **Observed behavior:**
  The request returns a typed `Total_request_timeout`.
- **Protocol/backend involved:** HTTP/2 client (`eta_http_eio` H2 multiplexer /
  `ocaml-h2` client connection).
- **Minimized input / frame sequence:**
  1. Client preface + SETTINGS
  2. Server SETTINGS
  3. Server `GOAWAY(last_stream_id=0x7FFFFFFF, error_code=0)`
  4. Server drains client frames so the hang is not a write-buffer stall
  5. Client request never receives a response and times out cleanly
- **Status:** `PASS`
- **Classification:** generated probe expectation was wrong; retained as
  timeout regression coverage.

## Current non-PASS probes

These probes still return typed Eta errors and do not hang, but the current
error class is less specific than the probe expects:

- `goaway_after_headers` — response HEADERS followed by GOAWAY currently
  returns `Connection_closed`; the probe expects
  `Connection_protocol_violation`.
- `push_promise` — server `PUSH_PROMISE` currently returns
  `Connection_closed`; the probe expects `Connection_protocol_violation`.
- `settings_invalid_enable_push` — server SETTINGS `ENABLE_PUSH=1` currently
  returns `Connection_closed`; the probe expects
  `Connection_protocol_violation`.

## Probes that passed (correctly handled) and are worth keeping

These probes cover client-side edge cases that are not tested elsewhere and
produced safe, typed outcomes:

- `headers_without_end_headers` — server sends HEADERS without END_HEADERS and
  stops; client times out cleanly.
- `continuation_never_ends` — long CONTINUATION chain without END_HEADERS;
  client returns `Continuation_flood`.
- `data_before_headers` — DATA frame arrives before response HEADERS; client
  returns `Connection_protocol_violation`.
- `rst_stream_before_headers` — RST_STREAM arrives before response HEADERS;
  client returns `Connection_protocol_violation`.
- `goaway_immediately` — GOAWAY with `last_stream_id=0` after handshake;
  client returns `Connection_protocol_violation`.
- `window_update_overflow` — WINDOW_UPDATE with `0x7FFFFFFF`; client returns
  `Connection_protocol_violation`.
- `data_after_end_stream` — DATA after HEADERS with END_STREAM; client ignores
  the late DATA and completes the response.
- `slow_headers` — server delays HEADERS beyond the timeout; client returns
  `Total_request_timeout`.
- `slow_body` — server dribbles DATA slowly; client returns
  `Total_request_timeout`.
- `settings_flood` — many SETTINGS frames; client returns
  `Settings_count_exceeded`.
- `ping_flood` — many PING frames; client returns `Ping_count_exceeded`.
- `headers_on_stream_zero` — HEADERS on stream 0; client returns
  `Connection_protocol_violation`.
- `priority_after_headers` — PRIORITY after response HEADERS; client ignores it
  and completes the response.
- `unknown_frame_type` — unknown frame type 0xFF; client ignores it and
  completes the response.
- `rst_stream_on_idle` — RST_STREAM for a stream the client never opened;
  client returns `Connection_protocol_violation`.
- `rst_stream_after_headers` — response HEADERS followed by RST_STREAM; client
  returns `Connection_protocol_violation`.
- `continuation_wrong_stream` — CONTINUATION on wrong stream; client returns
  `Connection_protocol_violation`.
- `headers_missing_status` — response HEADERS without `:status`; client returns
  `Connection_protocol_violation`.
- `valid_response` — sanity check; response body is consumed successfully.
