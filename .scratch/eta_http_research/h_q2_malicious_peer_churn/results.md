# H-Q2 Results

Verdict: PASS.

All six malicious peer churn fixtures triggered their circuit breaker, returned stream/fiber state to baseline after disconnect, plateaued in sampled memory/fd/fiber counters, and mapped to H-D-Errors typed errors.

```text
nix develop -c dune exec scratch/eta_http_research/h_q2_malicious_peer_churn/fixtures.exe
sampling malicious peer churn every 1s for 30s
ATTACK headers_rst_every_stream samples=30 first(live=0 rss=6440 fd=4 fibers=0) last(live=0 rss=6796 fd=4 fibers=0) error=stream_admission_rejected
PASS headers_rst_every_stream collected 30 samples
PASS headers_rst_every_stream circuit breaker triggered
PASS headers_rst_every_stream returned to baseline
PASS headers_rst_every_stream plateaued
PASS headers_rst_every_stream mapped to typed error
ATTACK goaway_mid_flight samples=30 first(live=0 rss=6444 fd=4 fibers=16) last(live=0 rss=6796 fd=4 fibers=0) error=connection_closed
PASS goaway_mid_flight collected 30 samples
PASS goaway_mid_flight circuit breaker triggered
PASS goaway_mid_flight returned to baseline
PASS goaway_mid_flight plateaued
PASS goaway_mid_flight mapped to typed error
ATTACK ping_flood samples=30 first(live=0 rss=6448 fd=4 fibers=0) last(live=0 rss=6796 fd=4 fibers=0) error=connection_closed
PASS ping_flood collected 30 samples
PASS ping_flood circuit breaker triggered
PASS ping_flood returned to baseline
PASS ping_flood plateaued
PASS ping_flood mapped to typed error
ATTACK header_churn samples=30 first(live=0 rss=6448 fd=4 fibers=0) last(live=0 rss=6800 fd=4 fibers=0) error=response_header_timeout
PASS header_churn collected 30 samples
PASS header_churn circuit breaker triggered
PASS header_churn returned to baseline
PASS header_churn plateaued
PASS header_churn mapped to typed error
ATTACK stream_id_jumps samples=30 first(live=0 rss=6452 fd=4 fibers=0) last(live=0 rss=6800 fd=4 fibers=0) error=stream_admission_rejected
PASS stream_id_jumps collected 30 samples
PASS stream_id_jumps circuit breaker triggered
PASS stream_id_jumps returned to baseline
PASS stream_id_jumps plateaued
PASS stream_id_jumps mapped to typed error
ATTACK rst_rate_exceeded samples=30 first(live=0 rss=6452 fd=4 fibers=0) last(live=0 rss=6800 fd=4 fibers=0) error=rst_rate_exceeded
PASS rst_rate_exceeded collected 30 samples
PASS rst_rate_exceeded circuit breaker triggered
PASS rst_rate_exceeded returned to baseline
PASS rst_rate_exceeded plateaued
PASS rst_rate_exceeded mapped to typed error
h_q2_malicious_peer_churn fixtures passed
```

Error mapping:

| Attack | Typed error class |
| --- | --- |
| HEADERS + RST_STREAM churn | `stream_admission_rejected` |
| GOAWAY mid-flight | `connection_closed` |
| PING flood | `connection_closed` |
| Header churn | `response_header_timeout` |
| Stream-id jumps | `stream_admission_rejected` |
| RST_STREAM rate limit | `rst_rate_exceeded` |

Residual risk:

- The fixture-owned fiber count is modeled because Eta does not expose runtime fiber census. H-Q2 still samples real GC live words, Linux RSS, and Linux fd count.
