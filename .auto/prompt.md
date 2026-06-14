# Autoresearch: Eta HTTPS (HTTP/1.1 over TLS) handshake latency

## Objective

Reduce Eta's **TLS handshake latency** under concurrent load on the HTTPS H1
server, measured over real sockets with `oha --disable-keepalive` driving the
standalone `h1_tls_probe.exe` server (fresh handshake per request).

This is the top remaining outlier in the broad server-load suite: Eta H1 TLS
shows a stable ~15-16ms p99 (vs Go/Node ~1-2ms), while H1 plain and H2 are
competitive.

## The diagnosis (already established — do NOT re-litigate)

Isolated, core-pinned measurements proved the p99 outlier is **entirely TLS
handshake cost**, not steady-state request handling:

- H1 TLS steady-state (keep-alive, n large): p50 ~0.2ms, p99 ~0.4ms — fine.
- A single full handshake costs ~1.4ms CPU (ECDHE-RSA, **RSA-2048 server
  signature** is the dominant op; cert is RSA-2048 from the test harness).
- Under c=16, handshakes serialize on the single-core Eio server → p50 ~2.66ms.
- The broad suite runs n=1000 keep-alive at c=16, so the 16 handshakes (1.6% of
  requests) land exactly at p99 → the reported ~15-16ms.

Confirmed already-correct (don't chase these again):
- TCP_NODELAY **is** set on accepted flows (`server.ml:set_tcp_nodelay`,
  applied via `accepted_flow` on the TLS path too) — Nagle is NOT the cause.
- The Tls_eio server context is built **once** per listener (in
  `run_https_on_socket`), not per connection.

The same `Tls_eio` path serves H2 TLS, so a faster handshake should also smooth
H2 TLS p99 (tracked as motivation; primary metric is H1 TLS).

## Metrics

- **Primary**: `h1_tls_hs_p50_us` (microseconds, **LOWER is better**) — median
  per-request latency when every request does a fresh handshake (c=16).
- **Secondary monitors** (log ALL every iteration):
  - `h1_tls_hs_p99_us` — handshake tail latency.
  - `h1_tls_hs_rps` — handshake throughput (must NOT regress).
  - `h1_tls_ka_p99_us` — keep-alive p99 at c=16 n=1000 (the literal broad-run
    symptom; confirms the win maps to the reported ~15-16ms).
  - `h1_tls_peak_rss_kb` — server peak RSS.
  - `success` — 1 only if every oha run kept successRate ≥ 0.999.

## How to Run

`./.auto/measure.sh` — outputs `METRIC name=number` lines. Builds release
`h1_tls_probe.exe`, then runs oha (HTTPS, 16 conns) REPS=3 for the handshake
(`--disable-keepalive`) and keep-alive shapes, reporting medians.

**CRITICAL: rebuild `h1_tls_probe.exe` after lib changes** (measure.sh does
this; a stale probe binary causes false PROBE_FAILED or stale results).

## Files in Scope

- `lib/http/tls/config.ml` — Eta TLS policy: `policy_version` (TLS_1_2,1_3),
  `policy_ciphers`, `policy_tls13_ciphers`, ALPN, server cert config. Cipher /
  version / group selection lever.
- `lib/http_eio/tls/tls_eio.ml` — the Eio wrapper over ocaml-tls: server
  context build, `server_of_flow_with_context`, record read/write, buffering.
  PRIMARY target for handshake-path overhead, session resumption, write
  coalescing of handshake flights.
- `lib/http_eio/server.ml` — `run_https_connection` (handshake invocation,
  `tls_handshake_timeout` with_timeout wrapper), ALPN dispatch, accept loop.
- `lib/http_eio/transport/*.ml` — shared TLS/socket plumbing if relevant.
- `http-testsuite/test/server_load/h1_tls_probe.ml` — the probe (harness; do
  NOT tune to cheat the load generator).
- `http-testsuite/lib/certs.ml` — generates the RSA-2048 test cert. Treat with
  care: changing the key type (e.g. to ECDSA) changes the workload for ALL
  servers in the broad suite, so it is NOT a fair Eta-only optimization. Only
  touch if mirroring a real server-config capability and noted explicitly.

## Off Limits

- Do not special-case benchmark paths/headers, or cheat oha.
- Do not weaken TLS security: no downgrading to insecure ciphers/versions,
  disabling cert validation, static/zero ephemeral keys, weak RNG, or skipping
  the server signature. Faster must stay correct AND secure.
- Do not tune `h1_tls_probe.ml` handlers to shortcut work.
- Do not break ALPN (h2/http1.1), SNI, or the existing TLS interop suite.

## Constraints

- Release profile only.
- `.auto/checks.sh` (H1 server/client + shared HTTP unit suites) must pass every
  kept iteration.
- Heavier conformance/interop suites (`dune build @interop @cve-regress`) must
  pass before any merge (run at finalize).
- `log_experiment` must include ALL secondary metrics every call.

## What's Been Tried

(Fresh session.) Candidate levers, roughly ordered — see `.auto/ideas.md`:

1. **TLS session resumption / tickets** — resumed handshakes skip the RSA
   signature entirely. Biggest potential win IF the client reuses tickets;
   verify oha behavior (`--disable-keepalive` opens fresh TCP each time — check
   whether it presents a session ticket / does 1-RTT resumption).
2. **Remove/defer the per-handshake `with_timeout` fork** in
   `run_https_connection` (sleeper fiber + Zzz node per handshake — the same
   anti-pattern removed from the H1 plain path for big wins).
3. **Multi-core accept for handshakes** — the single-core server serializes 16
   concurrent handshakes; the RSA sign is CPU-bound and embarrassingly
   parallel. A handshake-offload domain pool or `domain_policy` could parallel-
   ize the CPU-heavy handshake while keeping request handling semantics.
4. **TLS 1.3-only / group & cipher ordering** — ensure the fast path (TLS 1.3 +
   X25519 ECDHE) is negotiated; avoid any slow FFDHE/group fallback.
5. **ocaml-tls / mirage-crypto RSA backend** — confirm the fast bignum path is
   linked; the RSA-2048 sign is the dominant per-handshake cost.
6. **Handshake-flight write coalescing** in `tls_eio.ml` — fewer small socket
   writes during the multi-flight handshake.

## Noise

The `--disable-keepalive` p50 is low-noise (p90 ≈ p50). The `ka_p99` secondary
(n=1000 keep-alive) is noisier — use it as a corroborating symptom, not a
primary signal.
