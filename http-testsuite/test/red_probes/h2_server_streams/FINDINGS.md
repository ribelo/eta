# h2_server_streams findings

Run:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h2_server_streams/run.exe
```

## Current status

All probes in this family pass.

Resolved findings:

- `h2_streams_stalled_body_not_blocking`: a single stalled request body no
  longer blocks scheduling of complete concurrent streams.
- `h2_streams_empty_data_flood`: the per-connection empty-DATA limit now emits
  an H2 GOAWAY and closes the connection.
- `h2_streams_settings_flood_mid_stream`: the per-connection SETTINGS churn
  limit now emits an H2 GOAWAY and closes the connection.

## Probes worth keeping

- `h2_streams_stalled_body_not_blocking` — stalled request body plus complete
  concurrent streams.
- `h2_streams_data_interleaved` — interleaved DATA across 20 concurrent POST streams.
- `h2_streams_rst_during_bodies` — RST_STREAM on one partial body while other streams complete.
- `h2_streams_settings_lower_max_concurrent` — peer SETTINGS lowering `MAX_CONCURRENT_STREAMS` does not disrupt already-open client streams.
- `h2_streams_priority_self_dependency` — PRIORITY frame that makes a stream depend on itself is rejected.
- `h2_streams_tiny_data_chunks` — 1-byte DATA chunks on 40 concurrent streams.
- `h2_streams_headers_flood_no_data` — 80 concurrent HEADERS with `END_STREAM=true`.
- `h2_streams_empty_data_flood` — excessive empty DATA frames close the
  connection.
- `h2_streams_settings_flood_mid_stream` — excessive SETTINGS frames close the
  connection.
- `h2_streams_unread_bodies_interleaved` — handler returns without reading interleaved request bodies.
- `h2_streams_priority_on_stream_zero` — PRIORITY on stream 0 is rejected with GOAWAY.
