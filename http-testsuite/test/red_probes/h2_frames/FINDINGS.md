# h2_frames Red-Probe Findings

Run:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h2_frames/run.exe
```

## Fixed Finding

### `data_after_rst_stream`

- **Previous status:** FAIL
- **Current status:** PASS
- **Behavior now:** After the client resets stream 1 and sends late DATA on
  stream 1, the server keeps the connection usable and responds to a valid
  request on stream 3.
- **Regression:** covered by
  `test_h2c_server_ignores_data_after_peer_reset` in
  `test/http/test_eta_http_h2_server.ml`.

## Remaining Policy Gaps

### `headers_without_end_headers`

- **Current status:** POLICY_GAP
- **Observed behavior:** A `HEADERS` frame without `END_HEADERS`, followed by
  EOF instead of `CONTINUATION`, closes without an explicit GOAWAY.
- **Policy decision needed:** Eta can keep this as timeout/close behavior, or
  upgrade it to an explicit connection error with GOAWAY.

### `goaway_lower_last_stream`

- **Current status:** POLICY_GAP
- **Observed behavior:** Client GOAWAY with `last_stream_id=1` causes the server
  to close without responding to stream 1.
- **Policy decision needed:** decide whether received GOAWAY should allow
  already-open streams with ids at or below `last_stream_id` to complete.

## Passing Coverage Kept

The rest of the family currently passes and remains useful regression coverage:

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
