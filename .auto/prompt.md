# Autoresearch: Eta HTTP/2 server tail latency over real sockets

## Objective

Reduce Eta's HTTP/2 (h2c) **tail latency** under load, measured over real
sockets with the `oha` load generator driving the standalone `h2_probe.exe`
h2c server. Throughput work is done (a previous session took h2_rps_geomean
38,013 → 114,091, +200%, and Eta H2 plain is now ahead of Node h2c on RPS).
The remaining weakness is the **tail**:

| Case                | Mean RPS | Median RPS | **p99**  |
|---------------------|----------|------------|----------|
| H2 plain vs Node h2c| 1.10x    | 1.18x      | **1.77x**|
| H2 TLS  vs Go TLS   | 0.97x    | 1.03x      | **1.46x**|

(>1.0x p99 = Eta tail is *worse*.) p99 is dominated by GC pauses and
per-request/per-stream work that spikes occasionally rather than the steady
hot path. Steady-state throughput hides these spikes; p99 surfaces them.

## Metrics

- **Primary**: `h2_p99_us_geomean` (microseconds, **LOWER is better**) — geomean
  of per-endpoint p99 latency across root, user_id, static_1k, echo_1k.
- **Secondary monitors** (tradeoff guards, rarely override the primary):
  - `h2_p50_us_geomean` — median latency; watch that we don't trade median for tail.
  - `h2_rps_geomean` — throughput must NOT regress (the previous session's win).
  - `h2_peak_rss_kb` — server peak RSS; memory must not balloon.
  - per-endpoint `h2_<ep>_p99_us`, `h2_<ep>_p50_us`, `h2_<ep>_rps`.
  - `success` — 1 only if every endpoint kept successRate ≥ 0.999.

## How to Run

`./.auto/measure.sh` — outputs `METRIC name=number` lines. Builds the release
`h2_probe.exe`, then for each endpoint runs oha (1 conn / 16 streams, n=40000)
REPS=3 times and reports the median of rps/p99/p50. Peak server RSS sampled
from `/proc/PID/status` VmHWM.

**CRITICAL: the probe binary is rebuilt by measure.sh, but if you edit lib code
and run checks first, make sure `h2_probe.exe` is rebuilt before measuring — a
stale probe binary causes false "PROBE_FAILED / server not responding".**

## Files in Scope

- `lib/http/h2/*.ml` — in-house H2 state machine (connection, hpack, frame,
  stream, scheduler, settings, window, body, error_code).
- `lib/http_eio/h2_server_connection.ml` — H2 Eio server loop: reader/writer,
  handler switch, handler-timeout watchdog, stream lifecycle Hashtbls.
- `lib/http_eio/h1_server_connection.ml` — H1 server loop (shared helpers).
- `lib/http/server_request.ml`, `server_semconv.ml` — request plumbing.
- `lib/eta/*.ml` — runtime/effect interpreter (handler runs through it).
- `http-testsuite/test/server_load/h2_probe.ml` — the probe server (the harness;
  do NOT tune it to cheat the benchmark; only change if measurement is wrong).

## Off Limits

- Do not special-case benchmark paths/headers, or otherwise cheat oha.
- Do not weaken H2 conformance, security, cancellation, or timeout semantics.
- Do not tune `h2_probe.ml` request handlers to shortcut work.
- Do not optimize only the measured endpoints at the expense of general correctness.

## Constraints

- Release profile only.
- `.auto/checks.sh` (H2 server/client/HPACK/multiplexer unit suites) must pass
  every kept iteration.
- h2spec / interop / cve-regress must pass before any merge (run at finalize,
  NOT per iteration).
- `log_experiment` must include ALL secondary metrics every call.

## What's Been Tried

### This session (latency) — key results (13 experiments, 11 kept)
- Baseline p99 geomean 4639µs. Best: **2540µs (−45.3%)** — #11 (decimal content-length writer).
- Cumulative gains: p50 geomean −34%, rps geomean +45%, RSS −61%.

**THE big levers (in order of impact):**

1. **Removing per-op Eio timeout forks** (#4, #5) — the single biggest lever.
   Each `Eio.Time.with_timeout` / `Fiber.fork_daemon`+sleep forked a fiber +
   Zzz timer node + promise for a timeout that almost never fires. Removing
   them cut p99 by ~22-38% per targeted endpoint and RSS by ~33-39%.
   - #4 request_body_timeout: arm only after `schedule_read` if not already
     delivered (buffered DATA is synchronous). echo p99 −38%, RSS −33%.
   - #5 response_write_timeout: per-write `with_timeout` on ALL endpoints
     replaced with per-connection watchdog + Cancel.sub (t.write_watch slot).
     p99 geomean −22%, RSS −39%, rps +10%.
   - (handler_timeout was already watchdogged in the throughput session.)

2. **Deferred OTEL attribute/materialization** (#7, #8, #9) — second biggest.
   The server tracer eagerly built Semconv.request_attrs/response_attrs
   (string_of_int→snprintf, 6.5% CPU) + server metrics attrs PER REQUEST
   even though the probe runtime has no tracer/meter installed (tracing_enabled
   = metrics_enabled = false).
   - #7: `Effect.annotate_all_lazy` — only materialize span attrs when
     tracing_enabled. p50 −10.5%, rps +9%.
   - #8: Gate `request_metrics` on `Eta.Runtime.metrics_enabled` (requires
     adding the accessor). p50 −7.5%, rps +4%.
   - #9: Skip the whole span wrapper (named_kind/bind/catch) via
     `Effect.is_tracing_enabled` gate — when no tracer, run handler bare.
     rps +9%, p50 −8%.

3. **Per-response micro-optimizations** (real but smaller):
   - #2: Single-chunk fixed-body fast path (skip Bytes.concat copy per body).
   - #3: Share-on-unchanged header normalization (zero alloc when names
     already lowercase — the HTTP/2 common case).
   - #11: No-snprintf decimal writer for add_content_length_header (avoids
     per-response caml_format_int→sprintf chain for 0-4 digit lengths).
     p99 −6%, p50 −2%.

**Discarded experiments** (#6, #10, #12, #13):
   - #6: Diagnostic — disable OTEL to quantify cost. OTEL costs ~15% p99,
     ~24% rps. Discarded (workload change/cheating).
   - #10: Precompute content-length 0-9 strings. Discarded (within noise).
   - #12: Precompute 0-9999 content-length. Discarded (within noise).
   - #13: Larger minor GC heap. Discarded (neutral, probe tuning).

**Metric noise lesson**: The p99 primary is noise-limited (~150-250µs geomean
noise) for micro-optimizations. Body-endpoint p99 (static_1k, echo_1k) swings
wildly (3500-7000µs run-to-run). Smaller wins need p50 or rps as secondary
confirmations. When one endpoint is an extreme outlier vs its p50, re-run.

**Remaining untried targets** (deferred to ideas.md):
- Stream Hashtbl consolidation (hash_exn 2.6% + compare 2.2%).
- await_owner promise+command roundtrip (fiber context switch per response).
- HPACK decode string pooling.
- Eta.Runtime sync-handler fast path.
- Response body copy elimination in respond (Bigstringaf.of_string).

### Throughput-session learnings that inform tail work:

- **GC is the prime suspect for p99.** Previous session cut root H2
  minor_words/req 2695 → 2209 and GC CPU ~40% → ~18%, but allocation per request
  is still substantial. Each minor collection is a latency spike. Reducing
  per-request allocation directly shrinks the tail.
- **Per-request/per-op Eio primitives were the big throughput cost** (Fiber.first,
  Time.with_timeout). They're gone from the hot path now, replaced by a shared
  per-connection handler switch + one watchdog daemon. The watchdog polls on a
  timer (Eio_utils.Zzz) — its wakeups may contribute jitter; worth profiling.
- **HPACK decode allocates fresh name/value strings per header** — a major
  string allocator and thus a GC-pressure / tail contributor.
- The Eta runtime effect interpreter (eval/perform/resume) runs every handler;
  a sync-handler fast path could cut both latency and allocation.

### Ideas backlog
See `.auto/ideas.md` for deferred, higher-effort ideas (GC tuning, string
pooling, runtime fast path, watchdog jitter, write-timeout watchdog).
