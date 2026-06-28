# h2_frames Red-Probe Findings

Run:

```sh
nix develop -c dune exec http-testsuite/test/red_probes/h2_frames/run.exe
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

## Resolved Policy Gaps

### `headers_without_end_headers`

- **Previous status:** POLICY_GAP
- **Current status:** PASS
- **Behavior now:** A `HEADERS` frame without `END_HEADERS`, followed by EOF
  instead of `CONTINUATION`, is rejected as an incomplete header block.

### `goaway_lower_last_stream`

- **Previous status:** POLICY_GAP
- **Current status:** PASS
- **Behavior now:** A client GOAWAY with `last_stream_id=1` still allows the
  already-open stream 1 to receive its response.

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
- `data_after_rst_stream`
- `continuation_fragmentation`
- `rst_stream_on_idle`
- `data_on_stream_zero`
- `settings_on_nonzero_stream`
- `ping_on_nonzero_stream`
- `continuation_wrong_stream`
- `goaway_lower_last_stream`
- `headers_without_end_headers`
