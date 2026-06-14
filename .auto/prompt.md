# Autoresearch: Eta HTTPS (HTTP/1.1 over TLS) handshake throughput

## Objective

Reduce Eta's **TLS handshake latency under concurrent load** on the HTTPS H1
server, by making CPU-bound handshakes scale across domains (cores). Measured
over real sockets with `oha --disable-keepalive` driving the standalone
`h1_tls_probe.exe` server (fresh handshake per request), server spread across
multiple Eio domains.

This is the top remaining outlier in the broad server-load suite: Eta H1 TLS
~15-16ms p99 (vs Go/Node ~1-2ms).

## The diagnosis (already established — do NOT re-litigate)

The p99 outlier is NOT steady-state request handling (that's ~0.2ms p50) and NOT
per-handshake CPU (OpenSSL RSA-2048 sign is ~0.17ms — already fast). It is
**handshake serialization**:

- The probe server originally ran SINGLE-domain → 16 concurrent handshakes
  queue on one core (p50 2.66ms, p99 8.7ms, the broad-suite n=1000 p99 ~15ms).
- Enabling multi-domain accept (`ETA_SERVER_DOMAINS`, wired through
  `eta_server.start` → `start_https ~domain_manager ~domain_policy:Additional n`)
  drops p99 to ~2.2ms and rps +65% at 8 domains — BUT p50 only falls to ~1.7ms,
  ~10× the 0.17ms per-handshake CPU. **Handshakes do not scale linearly.**

The non-scaling = shared-state contention across domains. Prime suspects:
1. Per-connection bookkeeping under the global `server.ml` `t.mutex`:
   `register_pending_tls`, `register_transitioned_connection`,
   `record_tls_handshake`/`record_alpn_*`, `unregister_*` — ~5 lock ops per
   connection on ONE `Eio.Mutex` shared across all domains.
2. `tls_eio.ml` allocates `Cstruct.create 32768` per `feed_bio` and
   `Cstruct.create pending` per `drain_bio` (multiple per handshake) → bigarray
   malloc/free churn that contends across domains. Reuse per-connection buffers.
3. OpenSSL global locks / RNG; per-handshake `create_server_ssl`.

Confirmed already-correct: TCP_NODELAY is set on accepted flows; Tls_eio context
built once per listener. io_uring memlock is only 8MB → `Recommended` (31
domains) fails with ENOMEM; use a modest `Additional n` (8 is the sweet spot).

## Metrics

- **Primary**: `h1_tls_hs_p50_us` (microseconds, **LOWER is better**) — median
  per-request latency, fresh handshake per request (`--disable-keepalive`),
  c=16, server across ETA_TLS_DOMAINS (default 8) domains.
- **Secondary monitors** (log ALL every iteration):
  - `h1_tls_hs_p99_us` — handshake tail latency.
  - `h1_tls_hs_rps` — handshake throughput (higher better; must NOT regress).
  - `h1_tls_ka_p99_us` — keep-alive p99 at c=16 n=1000 (broad-run symptom).
  - `h1_tls_peak_rss_kb` — server peak RSS (more domains = more RSS; watch it).
  - `success` — 1 only if every oha run kept successRate ≥ 0.999.

## How to Run

`./.auto/measure.sh` — outputs `METRIC name=number` lines. Builds release
`h1_tls_probe.exe`, starts it with `ETA_SERVER_DOMAINS` domains on isolated
cores (taskset 4-19), then runs oha (HTTPS, c=16) REPS=3 for the handshake
(`--disable-keepalive`) and keep-alive shapes, reporting medians.

**CRITICAL: rebuild after lib changes** (measure.sh does this).

## Files in Scope

- `lib/http_eio/server.ml` — accept loop, `run_https_connection`, the global
  `t.mutex` + per-connection bookkeeping (`register_*`/`unregister_*`/
  `record_*`). PRIMARY target for cross-domain contention: make stats/registry
  per-domain or lock-free so handshakes scale. Mind `portable` when state
  crosses domains.
- `lib/http_eio/tls/tls_eio.ml` — OpenSSL Eio wrapper. `feed_bio`/`drain_bio`
  allocate fresh Cstructs per call; reuse per-connection buffers. Handshake I/O
  loop, `create_server_ssl` per connection.
- `lib/http/tls/openssl.ml` — OpenSSL ctx/ssl bindings; check for global locks,
  RNG setup, session-cache options.
- `lib/http_eio/server.ml` domain plumbing (`additional_domains`,
  `domain_policy`) — already supports `Additional n`.
- `http-testsuite/lib/eta_server.ml` — wires `ETA_SERVER_DOMAINS` →
  `start_https ~domain_manager ~domain_policy`. Harness config.
- `http-testsuite/test/server_load/h1_tls_probe.ml` — the probe (harness).
- Eta parallelism substrate (`Eta.Par`) and Eio domain/executor primitives —
  prefer these over hand-rolled threading; honor mode/portability fences.

## Off Limits

- Do not special-case benchmark paths/headers, or cheat oha.
- Do not weaken TLS security: no downgrading ciphers/versions, disabling cert
  validation, static/zero ephemeral keys, weak RNG, or skipping the server
  signature. Faster must stay correct AND secure.
- Do not break ALPN (h2/http1.1), SNI, connection tracking/shutdown semantics,
  or the TLS interop suite.
- Do not tune `h1_tls_probe.ml` handlers to shortcut work.

## Constraints

- Release profile only.
- `.auto/checks.sh` (H1 server/client + shared HTTP unit suites) must pass every
  kept iteration.
- Heavier conformance/interop suites (`dune build @interop @cve-regress`) must
  pass before any merge (run at finalize).
- io_uring memlock is 8MB → keep domain count modest (≤ ~16).
- `log_experiment` must include ALL secondary metrics every call.

## What's Been Tried

- Baseline #1 (single-domain, 1-core pin): p50 2.69ms — archived; target changed
  to multi-domain throughput.
- Multi-domain enablement (config, not a counted opt): 8 domains → p99 8.7→2.2ms,
  rps +65%, but p50 stuck ~1.7ms (non-linear scaling = contention).
- NEXT (ideas.md): (1) reuse per-connection feed/drain buffers in tls_eio.ml;
  (2) cut/replace the global `t.mutex` per-connection bookkeeping with per-domain
  state; (3) check OpenSSL RNG/global-lock contention.
