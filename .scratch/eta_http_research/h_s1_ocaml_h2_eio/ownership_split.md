# H-S1 Ownership Split

This is the current split observed from the P2/P3 research adapter. It is not
the final eta-http implementation boundary.

## ocaml-h2 Owns

- HTTP/2 connection preface and SETTINGS handshake.
- HPACK encode/decode.
- Stream identifiers and stream state machine.
- Frame parsing and serialization.
- Flow-control accounting inside the h2 scheduler.
- Response trailers dispatch.
- RST_STREAM and GOAWAY frame processing.
- Distinction between stream-level and connection-level errors.

## Eta-http Adapter Must Own

- Eio `Flow` read/write loops and structured fiber lifecycle.
- Wakeup discipline for h2 `Yield` states: register one wakeup callback and
  wait for it; do not repeatedly call `yield_writer` for the same state.
- Request admission after connection closure or GOAWAY. Current evidence shows
  a request submitted after GOAWAY can hang unless the adapter gates on the
  connection error handler; `Client_connection.is_closed` alone is too weak.
- Mapping h2 stream/connection errors into Eta/Cause-shaped typed failures.
- User cancellation semantics: close/reset response bodies and release any
  eta-http stream metadata. The current cancellation fixture proves this as an
  adapter-owned counter returning to zero, not as an exposed h2 internal stream
  count.
- Admission and fairness policy while a stream is flow-control stalled. h2 owns
  the scheduler accounting; eta-http still owns user-visible timeouts and
  whether a stalled stream is cancelled, drained, retried, or left open.
- Lower-copy bridging between Eio buffers and `Bigstringaf.t`; current probes
  copy through `Cstruct.t -> string -> Bigstringaf.t`.
- Pool/permit counters and any public timeout taxonomy.

## GOAWAY Caveat

The current passing matrix covers error GOAWAY via
`Server_connection.report_exn`, where the client connection error handler
fires and the adapter can stop admitting new requests. It does not prove
graceful `NO_ERROR` GOAWAY with precise `last_stream_id` cutoff. Code
inspection showed h2's client-side `process_goaway_frame` ignores
`last_stream_id` and sends GOAWAY through connection shutdown. The raw
`goaway_raw_probe` confirms the public state machine closes after flushing but
does not notify either the connection error handler or the stream error handler
for a stream above the GOAWAY cutoff.

## Current Probe Size

Measured with:

```sh
wc -l scratch/eta_http_research/h_s1_ocaml_h2_eio/p2_eio_tcp_get.ml scratch/eta_http_research/h_s1_ocaml_h2_eio/stage2_matrix.ml scratch/eta_http_research/h_s1_ocaml_h2_eio/goaway_raw_probe.ml scratch/eta_http_research/h_s1_ocaml_h2_eio/nghttp2_h2_smoke.ml
```

Output:

```text
  206 scratch/eta_http_research/h_s1_ocaml_h2_eio/p2_eio_tcp_get.ml
  582 scratch/eta_http_research/h_s1_ocaml_h2_eio/stage2_matrix.ml
  111 scratch/eta_http_research/h_s1_ocaml_h2_eio/goaway_raw_probe.ml
  184 scratch/eta_http_research/h_s1_ocaml_h2_eio/nghttp2_h2_smoke.ml
 1083 total
```

Interpretation: the proof harness is intentionally larger than a production
adapter because it embeds server fixtures and assertions. The reusable adapter
core in a later eta-http implementation should be smaller, but it must still
own the lifecycle, wakeup, request-admission, error-mapping, and buffer-bridge
responsibilities above.
