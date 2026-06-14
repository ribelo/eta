# Autoresearch: Eta HTTP/1.1 server tail latency over real sockets

## Objective

Reduce Eta's HTTP/1.1 server **tail latency** (and close the throughput gap)
under load, measured over real sockets with `oha` driving the standalone
`h1_probe.exe` H1 server.

This follows a successful H2 latency session (h2_p99_us_geomean 4639→2540µs,
−45%; rps +45%; RSS −61%). The server-load comparison afterward showed H1 is
now the weakest spot vs Go:

| Case                  | Mean RPS | Median RPS | p99 (Eta/ref) |
|-----------------------|----------|------------|---------------|
| H1 Eta / Node plain   | 1.34x    | 1.45x      | 0.81x ✅      |
| **H1 Eta / Go plain** | **0.81x**| **0.80x**  | **1.55x ❌**  |

(RPS >1 = Eta faster; p99 <1 = Eta lower/better.) Eta H1 beats Node but loses
to Go on both throughput (0.81x) and tail (1.55x) — the worst tail in the suite.

## The key insight (why this session should work)

The H1 server (`h1_server_connection.ml`) still has the SAME anti-patterns the
H2 session eliminated for big wins:

1. **Per-op Eio timeout forks** — `with_timeout` on write (line ~173), body
   read (~369), response body (~873), handler (~1042-1055 with `Fiber.first`),
   and request-head read (~1093-1103). Each forks a fiber + Zzz timer + promise
   for a timeout that almost never fires. The H2 fixes (#4 sync-skip, #5
   per-connection watchdog) gave −22 to −38% p99 and −33 to −39% RSS.
2. **OTEL metrics gate bug** — `request_metrics` (line ~1018) is gated only on
   `enable_otel`, NOT `metrics_enabled`. Builds metric attrs per request even
   with no meter. H2 #8 fixed this; the `Eta.Runtime.metrics_enabled` accessor
   already exists on master.
3. The shared `server_tracer.ml` lazy-attr / `is_tracing_enabled` fixes (#7,#9)
   already benefit H1 — which is partly why H1 already beats Node.

## Metrics

- **Primary**: `h1_p99_us_geomean` (microseconds, **LOWER is better**) — geomean
  of per-endpoint p99 across root, user_id, static_1k, echo_1k.
- **Secondary monitors**:
  - `h1_p50_us_geomean` — median latency (cleaner signal than p99 for small wins).
  - `h1_rps_geomean` — throughput must NOT regress (close the Go gap, not widen it).
  - `h1_peak_rss_kb` — server peak RSS.
  - per-endpoint `h1_<ep>_p99_us`, `h1_<ep>_p50_us`, `h1_<ep>_rps`.
  - `success` — 1 only if every endpoint kept successRate ≥ 0.999.

## How to Run

`./.auto/measure.sh` — outputs `METRIC name=number` lines. Builds release
`h1_probe.exe`, then for each endpoint runs oha (HTTP/1.1, 16 keep-alive
connections, n=40000) REPS=3 times and reports the median of rps/p99/p50.

**CRITICAL: rebuild `h1_probe.exe` after lib changes** (measure.sh does this,
but a stale probe binary causes false PROBE_FAILED).

## Files in Scope

- `lib/http_eio/h1_server_connection.ml` — H1 Eio server loop: read head, parse,
  handler dispatch, response write, keep-alive, per-op timeouts. PRIMARY target.
- `lib/http/h1/*.ml` — H1 framing: request parse, response write, body, chunked.
- `lib/http/server_request.ml`, `server_tracer.ml`, `server_semconv.ml` — shared
  request plumbing + observability (already partly optimized; H1-specific gates
  may remain).
- `lib/eta/*.ml` — runtime/effect interpreter (handler runs through it).
- `http-testsuite/test/server_load/h1_probe.ml` — the probe (harness; do NOT
  tune to cheat the load generator).

## Off Limits

- Do not special-case benchmark paths/headers, or cheat oha.
- Do not weaken H1 correctness, keep-alive, chunked encoding, security, or
  cancellation/timeout semantics.
- Do not tune `h1_probe.ml` handlers to shortcut work.

## Constraints

- Release profile only.
- `.auto/checks.sh` (H1 server/client + shared HTTP unit suites) must pass every
  kept iteration.
- Heavier conformance/interop suites must pass before any merge (run at finalize).
- `log_experiment` must include ALL secondary metrics every call.

## What's Been Tried

(Fresh session — H1 focus. Proven playbook from the H2 latency session:)

- **THE big lever (H2): removing per-op Eio timeout forks.** Replace per-op
  `with_timeout`/`fork_daemon`+sleep with: (a) sync-skip — arm the timeout only
  if the op didn't complete synchronously; (b) per-connection watchdog + a
  single `Cancel.sub` deadline slot polled by one daemon. Apply the same to H1's
  write/body/handler/head-read timeouts.
- **Defer/gate OTEL work**: gate `request_metrics` on `Eta.Runtime.metrics_enabled`
  (H2 #8). Confirm H1's tracer path already uses the shared `is_tracing_enabled`
  skip.
- **Metric noise lesson**: p99 is noisy (body endpoints swing most); cross-check
  p50 + rps + RSS, and re-run when one endpoint p99 is an extreme outlier.

See `.auto/ideas.md` for the ordered backlog.
