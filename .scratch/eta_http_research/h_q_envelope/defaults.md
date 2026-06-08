# H-Q Envelope Defaults

These are eta-http v1 security defaults. The original H-D1 scratch envelope
accepted them as partial because it lacked byte-level HTTP/2 hooks. S4 moved
the deferred rows to the real ocaml-h2 adapter boundary and rechecked them.

| Knob | Default | Justification | Typed H-D-Errors variant |
| --- | ---: | --- | --- |
| `max_concurrent_stream_attempts` | `128` | H-D1 rapid reset evidence used 1000 attempts and stayed bounded while admitting useful h2 concurrency. Counts active plus cancelled attempts. | `Stream_admission_rejected` |
| `max_rst_per_second_per_connection` | `100/sec` | Normal client cancellation should be far below this on one connection. The fixture uses 250/sec and trips the breaker. | `Rst_rate_exceeded` |
| `max_ping_per_second` | `100/sec` | PING is diagnostic, not data. 100/sec is already far above health checks and below the 1000/sec attack fixture. | `Ping_rate_exceeded` |
| `response_header_max_change_rate` | `32/sec` | A normal response has one header block. 32/sec leaves room for redirects and retries while bounding metadata churn. S4 enforces this at the raw h2 HEADERS boundary. | `Response_header_change_rate_exceeded` |
| `max_settings_per_second` | `10/sec` | SETTINGS is connection configuration and should occur at handshake or rare reconfiguration. 10/sec is intentionally generous. S4 enforces this at the raw h2 SETTINGS boundary. | `Settings_churn_rate_exceeded` |
| `max_window_updates_per_second` | `1000/sec` | Large streaming responses legitimately need flow-control updates. The fixture uses 2000/sec and trips the policy while H-D1 stream state returns to baseline. | `Connection_protocol_violation` |
| `max_goaway_per_connection` | `1` | GOAWAY is terminal for an HTTP/2 connection. More than one is churn policy, not stream recovery. S4 enforces this at the raw h2 GOAWAY boundary. | `Connection_closed` |
| `max_goaway_churn_per_origin_per_minute` | `30/min` | Allows deploy or load-balancer churn, but bounds repeated fresh-connection termination loops. S4 covers the raw GOAWAY adapter side; per-origin cross-connection aggregation remains a future pooling policy if the public client starts reusing h2 connections across requests. | `Connection_closed` |
| `max_data_idle_per_stream` | `10s` | Matches eta-http timeout taxonomy: body progress must be observed. The lab uses a shorter internal timeout to keep the fixture fast. | `Response_body_idle_timeout` |
| `hpack_decoded_max_bytes` | `256KiB` | Inherited from H-Q3: 4x the synthetic OTel/header inventory p99 and aborts 10KiB-to-100MiB decoded bombs. | `Hpack_decode_overflow` |
| `continuation_max_accumulator_bytes` | `64KiB` | Inherited from H-Q3: 4x the large-header baseline and aborts around frame 64 in the CONTINUATION flood. | `Continuation_flood` |
| `max_header_name_bytes` | `8192` | Much larger than realistic metadata names; pairs with value/list caps to bound normalization work. S4 enforces this after ocaml-h2 header decode and before public response exposure. | `Header_invalid` |
| `max_header_value_bytes` | `65536` | Matches the H-Q3 large-header inventory p99 before applying the 4x decoded cap at the HPACK boundary. | `Header_invalid` |
| `max_allocator_words_per_admitted_frame_active` | `2260 words/frame` | Twice the H-D1 benign baseline of 1129.6 minor words/stream. Current selected active-path rates are 281.17, 153.84, and 98.43 words/frame; the post-disconnect metric remains secondary at 0.00. | `Connection_protocol_violation` |

## Prior Art Notes

This table follows the H-Q3 precedent: defaults must cite measurement,
protocol shape, or prior evidence. It does not claim parity with nghttp2,
hyper, Go `net/http2`, or undici yet; that comparison is a follow-up for the
implementation epic if these defaults are promoted unchanged.
