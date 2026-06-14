# H1 TLS handshake — ideas backlog & findings

## Status: key wins captured; benchmark at an environmental ceiling

### Kept (committed)
- **Multi-domain HTTPS** (`ETA_SERVER_DOMAINS`, eta_server → start_https): the
  direct fix for the broad-suite single-domain ~15ms p99. ka_p99 45ms→~14ms.
- **#11 buffer-reuse** (tls_eio feed/drain): RSS −23%, p50 down (noisy).
- **#12 session-cache-OFF** (`SSL_SESS_CACHE_OFF`): drops the global per-handshake
  session-cache write-lock; hs_p99 −11%, rps +4%. Resumption still via tickets.

### Tried & discarded / dead ends
- **#14 caml_enter/leave_blocking_section around SSL_do_handshake**: correct
  multicore change (long C call should release the runtime) but NEUTRAL at the
  measured workload; only marginal at c=96/16-domains. Reverted. Worth landing
  as a standalone correctness fix outside this benchmark.
- **RSA blinding lock**: NOT the serializer — ECDSA cert scales the same (~1.7×
  for 16 domains).

### The ceiling (why further throughput work is unproductive here)
Handshake throughput hard-caps at **~10,500 handshakes/s** and *degrades* with
concurrency (c=48/96 lower than c=16), independent of oha cores (8→12), domain
count (8→16), or runtime-release. So the cap is **environmental** — kernel
loopback / single listening-socket accept queue / oha client-side handshake
cost — not an Eta library bottleneck. Per-handshake server CPU (~0.17ms) is
already competitive. Latency p50 (~1.4ms at c=16) is round-trip/scheduling
bound.

### Untried (likely low value here, may matter elsewhere)
- `SSL_CTX_set_num_tickets(ctx, 1)` — server issues 2 NewSessionTickets per
  handshake (post-handshake CPU + a write); 1 is enough for most clients. Real
  per-handshake work cut, but post-handshake so won't move handshake latency,
  and won't lift the environmental throughput ceiling. Touches resumption.
- Per-domain SSL_CTX — would help only if a shared-CTX lock were the bottleneck;
  ECDSA result suggests it isn't.
- Lift the benchmark ceiling (a faster/native multi-process TLS client, or
  measure server CPU per handshake directly) to expose any remaining scaling.

### Recommendation
The user's goal (H1 TLS p99 competitive) is addressed by multi-domain + the two
library opts. Consider finalizing this session and, if desired, opening a new
session for **H2 TLS p99 / steady-state echo_1k** (the other reported weak spot),
which is a different code path (h2 multiplexer) not subject to this ceiling.
