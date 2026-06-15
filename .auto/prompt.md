# Autoresearch: Eta H2-over-TLS steady-state tail latency

## Objective

Reduce Eta's **H2-over-TLS steady-state tail latency**, measured keep-alive
over real sockets (oha HTTP/2, multi-domain server). The remaining weak spot
after the H1 TLS handshake session: isolated, Eta H2 TLS echo_1k p99 ~1.2-2.2ms
vs Go ~0.74ms (1.6-3×). The gap is roughly uniform across non-file endpoints
(root/user/echo all ~2ms p99 at c=16 p=16), so it is the **shared H2+TLS
steady-state request path**, NOT a handshake artifact (keep-alive isolates it)
and NOT the static_1k outlier (that's handler file-I/O, off-limits).

## The diagnosis (already established — do NOT re-litigate)

- Steady-state, not handshake: keep-alive runs (single conn, p=128) show echo
  p99 ~1.05ms; the gap vs Go grows with stream concurrency. Handshake cost is
  amortized away here.
- Uniform across endpoints → the lever is the h2 server path + TLS record
  read/write shared by all requests, not any one handler.
- static_1k is handler-bound (`read_file` = `open_in_bin`+`really_input`+close
  per request in the testsuite handler) → off-limits; do NOT tune it and do NOT
  treat its p99 as the primary signal.
- Already in place from the H1 TLS session (benefit H2 TLS too):
  `SSL_SESS_CACHE_OFF`, tls_eio feed/drain buffer reuse, multi-domain HTTPS
  (`ETA_SERVER_DOMAINS`), `caml_enter_blocking_section` around SSL_do_handshake.

## Metrics

- **Primary**: `h2_tls_echo_p99_us` (µs, **LOWER** is better) — echo_1k p99
  (full body read+write path; the user's cited gap endpoint).
- **Secondary monitors** (log ALL every iteration):
  - `h2_tls_<ep>_p99_us` / `h2_tls_<ep>_p50_us` / `h2_tls_<ep>_rps` for
    echo_1k, root, user, static_1k.
  - `h2_tls_p50_us_geomean`, `h2_tls_rps_geomean` (throughput guard).
  - `h2_tls_peak_rss_kb`.
  - `success` — 1 only if every oha run kept successRate ≥ 0.999.

## How to Run

`./.auto/measure.sh` — builds release `h2_tls_probe.exe`, starts it with
`ETA_SERVER_DOMAINS` (default 8) on isolated cores (taskset 4-19), runs oha
HTTP/2 keep-alive (taskset 20-27, c=16 p=16 n=20000) REPS=3 per endpoint,
reports medians. Low-noise (oha on 8 cores, not the bottleneck).

**CRITICAL: rebuild after lib changes** (measure.sh does this).

## Files in Scope

- `lib/http_eio/h2_server_connection.ml` — H2 Eio server: stream demux, HEADERS/
  DATA frame handling, flow control, response write path. PRIMARY target.
- `lib/http/h2/*.ml` — H2 framing: HPACK decode/encode, DATA write, flow-control
  accounting.
- `lib/http_eio/tls/tls_eio.ml` — steady-state TLS record read/write path
  (`single_read`/`single_write`), the per-request encrypt/decrypt overhead.
- `lib/http_eio/server.ml` — HTTPS accept / ALPN h2 dispatch / connection
  tracking (per-connection bookkeeping under the global mutex).
- `lib/http_eio/server_request.ml`, `server_tracer.ml`, `server_semconv.ml` —
  shared request plumbing/observability (check for per-request allocs/gates).
- Eta parallelism substrate (`Eta.Par`) and Eio domain/executor primitives;
  honor `portable`/mode fences for state crossing domains.

## Off Limits

- Do NOT tune the testsuite handlers (esp. `read_file` in static_1k) — that is
  application code, not Eta. The static_1k p99 reflects handler file-I/O.
- Do NOT special-case benchmark paths/headers or cheat oha.
- Do NOT weaken TLS/H2 security or correctness: framing, flow-control, stream
  lifecycle, ALPN, cancellation, or the interop/cve-regress suites.
- Do NOT weaken keep-alive or chunked/streaming semantics.

## Constraints

- Release profile only.
- `.auto/checks.sh` (H1/H2 server/client + shared HTTP unit suites) must pass
  every kept iteration.
- Heavier conformance/interop suites (`dune build @interop @cve-regress`) must
  pass before any merge (run at finalize).
- io_uring memlock ~8MB → keep domain count modest (≤ ~16).
- `log_experiment` must include ALL secondary metrics every call.

## What's Been Tried / Inherited

- Inherited from H1 TLS session (helps H2 TLS too): `SSL_SESS_CACHE_OFF`,
  tls_eio buffer reuse, multi-domain HTTPS, `caml_enter_blocking_section`.
- Candidate levers (see ideas.md): per-request TLS record write coalescing /
  batching across streams; HPACK encode/decode alloc reuse; h2 response write
  path (single writev for HEADERS+DATA where flow-control allows); shared-mutex
  per-connection bookkeeping contention under many concurrent streams; Eio
  scheduling hops per frame.

## Noise

echo_1k p99 is moderately noisy at low n; c=16 p=16 n=20000 REPS=3 median is
stable (±a few %). rps_geomean and p50 are cleaner corroboration.
