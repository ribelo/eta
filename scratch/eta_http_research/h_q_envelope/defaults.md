# H-Q Envelope Defaults

These are proposed eta-http v1 public config knobs. Defaults are accepted for
the current scratch envelope; byte-level deferred rows must be rechecked when
the ocaml-h2 adapter exposes the missing hooks.

| Knob | Default | Justification | Typed H-D-Errors variant |
| --- | ---: | --- | --- |
| `max_concurrent_stream_attempts` | `128` | H-D1 rapid reset evidence used 1000 attempts and stayed bounded while admitting useful h2 concurrency. Counts active plus cancelled attempts. | `Stream_admission_rejected` |
| `max_rst_per_second_per_connection` | `100/sec` | Normal client cancellation should be far below this on one connection. The fixture uses 250/sec and trips the breaker. | `Rst_rate_exceeded` |
| `max_ping_per_second` | `100/sec` | PING is diagnostic, not data. 100/sec is already far above health checks and below the 1000/sec attack fixture. | `Connection_closed` |
| `response_header_max_change_rate` | `32/sec` | A normal response has one header block. 32/sec leaves room for redirects and retries while bounding metadata churn. Requires byte-level header hook before final enforcement. | `Decode_error` |
| `max_settings_per_second` | `10/sec` | SETTINGS is connection configuration and should occur at handshake or rare reconfiguration. 10/sec is intentionally generous. Requires byte-level SETTINGS hook before final enforcement. | `Decode_error` |
| `max_window_updates_per_second` | `1000/sec` | Large streaming responses legitimately need flow-control updates. The fixture uses 2000/sec and trips the policy while H-D1 stream state returns to baseline. | `Decode_error` |
| `max_goaway_per_connection` | `1` | GOAWAY is terminal for an HTTP/2 connection. More than one is churn policy, not stream recovery. Requires byte-level GOAWAY hook before final enforcement. | `Connection_closed` |
| `max_goaway_churn_per_origin_per_minute` | `30/min` | Allows deploy or load-balancer churn, but bounds repeated fresh-connection termination loops. Requires H-D5/raw GOAWAY coverage before final enforcement. | `Connection_closed` |
| `max_data_idle_per_stream` | `10s` | Matches eta-http timeout taxonomy: body progress must be observed. The lab uses a shorter internal timeout to keep the fixture fast. | `Response_body_idle_timeout` |
| `hpack_decoded_max_bytes` | `256KiB` | Inherited from H-Q3: 4x the synthetic OTel/header inventory p99 and aborts 10KiB-to-100MiB decoded bombs. | `Hpack_decode_overflow` |
| `continuation_max_accumulator_bytes` | `64KiB` | Inherited from H-Q3: 4x the large-header baseline and aborts around frame 64 in the CONTINUATION flood. | `Continuation_flood` |
| `max_header_name_bytes` | `8192` | Much larger than realistic metadata names; pairs with value/list caps to bound normalization work. Requires byte-level header hook before final enforcement. | `Decode_error` |
| `max_header_value_bytes` | `65536` | Matches the H-Q3 large-header inventory p99 before applying the 4x decoded cap at the HPACK boundary. | `Decode_error` |
| `max_allocator_words_per_attack_frame_after_warmup` | `128 words/frame` | Allows small adapter bookkeeping but rejects attack-proportional allocation after the breaker disconnects. Current run measured `0.00` words/frame after warm-up. | `Decode_error` |

## Prior Art Notes

This table follows the H-Q3 precedent: defaults must cite measurement,
protocol shape, or prior evidence. It does not claim parity with nghttp2,
hyper, Go `net/http2`, or undici yet; that comparison is a follow-up for the
implementation epic if these defaults are promoted unchanged.
