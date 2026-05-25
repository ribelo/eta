# Autoresearch: Eta HTTP client warm-loop performance

## Objective

Make Eta's `eta-http` warm-loop client competitive with Go's `net/http` on
the perf_compare benchmark. Two concrete problems frame the work:

1. **H1 plain GET 1k has a ~44 ms per-request floor.** Go does the same
   work in ~18 µs. That is roughly 2400× slower and almost certainly a
   bug (a stray sleep, a synchronous flush waiting on something, or
   pool/scheduling pessimism), not raw CPU cost.
2. **H2/TLS warm reuse is broken.** Every H2 GET after the warmup pool
   is established times out. Go and curl both succeed. Whatever Eta is
   doing on the second request over a kept-alive TLS+H2 connection is
   wrong.

Once those two are addressed we expect H1 latency to fall by orders of
magnitude and H2 to start producing real samples; tightening the
remaining gap (e.g. caddy h2 POST 1m where Eta is ~3× slower than Go) is
follow-on work.

## Reference numbers (release, commit a11749b, full iteration counts)

```
scenario               |    Eta warm |  Go warm | curl CLI
nginx h1 plain GET 1k  |      44.015 |    0.018 |    3.195   ms median
nginx h2 tls   GET 1k  | timeout >2s |    0.023 |    4.741
nginx h2 tls   GET 1m  | timeout >2s |    0.432 |    4.893
caddy h2 tls   POST 1m |       5.395 |    1.731 |    7.900
```

Goal posts:
- nginx h1 plain GET 1k: **target < 0.5 ms** (within ~25× of Go is the
  first milestone; Go itself is 18 µs).
- nginx h2 tls GET 1k / 1m: **stop timing out**, then drive median into
  the sub-millisecond range.
- caddy h2 tls POST 1m: **within 2× of Go** (~3.5 ms).

## Metrics

The benchmark runs in a reduced "loop mode" (15 iters per scenario,
3 warmup, 500 ms Eta timeout cap) so each iteration stays under ~60 s.

- **Primary**: `eta_total_ms` — sum of Eta median ms across the 4
  scenarios. Errored scenarios contribute the timeout cap (currently
  500 ms each), so the baseline is dominated by H2 failures. **Lower is
  better.**
- **Secondary**:
  - `eta_errors` — count of scenarios where Eta failed (target: 0).
  - `eta_h1_get_1k_ms`, `eta_h2_get_1k_ms`, `eta_h2_get_1m_ms`,
    `eta_h2_post_1m_ms` — per-scenario Eta median.
  - `go_total_ms`, `go_h1_get_1k_ms`, ... — Go medians, used as a sanity
    check that the host is not under load. Should be roughly stable
    across runs.

## How to run

```
./autoresearch.sh
```

Internally:
1. `nix develop -c dune build --profile release http-testsuite/test/perf_compare/run.exe`
2. `nix develop -c dune exec --profile release --no-build` of the same
   target, with `ETA_PERF_ITERS / ETA_PERF_WARMUP / ETA_PERF_TIMEOUT_MS`
   exported.
3. Locate the JSON written under `http-testsuite/results/<run-id>/`
   and emit `METRIC name=value` lines from a small Python summariser.

The `perf_compare` executable was modified (this branch) to honour those
three env vars; without them it preserves the original full-suite
behaviour.

## Files in scope (likely places to fix things)

- `packages/eta-http/client/client.ml(.mli)` — connection pool, request
  pipelining, idle reuse. The H1 44 ms latency and H2 reuse bug both
  most likely live here.
- `packages/eta-http/client/retry.ml`, `idempotency.ml` — retry policy
  and idempotency keys; check whether retry/back-off is silently adding
  delay.
- `packages/eta-http/h1/client.ml`, `h1/parse.ml`, `h1/write.ml` — H1
  request/response framing and the per-request lifecycle.
- `packages/eta-http/h2/connection.ml`, `multiplexer.ml`, `writer.ml`,
  `stream_state.ml`, `frame.ml`, `admission.ml` — H2 connection,
  multiplexer, stream lifecycle. The "second request after warmup
  hangs" symptom likely involves stream state, window updates, or
  multiplexer dispatch.
- `packages/eta-http/transport/alpn.ml` — ALPN selection during TLS.
- `packages/eta-http/tls/config.ml` — TLS handshake wiring.
- `packages/eta-http/body/{chunked,source,stream,transducer}.ml` —
  body sourcing/sinking; could matter for the 1 MiB cases.
- `packages/eta/effect.ml`, `runtime.ml`, `schedule.ml`, `duration.ml` —
  if profiling fingers a runtime/scheduler issue rather than HTTP
  framing.
- `http-testsuite/test/perf_compare/run.ml` — the benchmark itself.
  Modify if you need additional instrumentation (per-phase timings,
  more scenarios). Remember the `ETA_PERF_*` env-var hooks already
  exist.
- `http-testsuite/lib/*.ml` — shared fixture helpers (servers, certs,
  bodies). Touch only if a test scaffolding bug is in the way.

## Off limits

- Do **not** alter the reference clients (Go helper string in `run.ml`,
  curl invocation). They are the comparison baseline.
- Do **not** weaken the workload (e.g. switch to a smaller body, drop a
  scenario, raise the timeout silently) just to make the metric look
  better. Loosen iteration counts via `ETA_PERF_ITERS` only when
  intentionally trading stability for speed; document it.
- Do **not** edit `.backlog/`, `.review/`, `journal.md`, `_build/`.
  `.backlog/` files show as dirty in `git status` but are gitignored —
  ignore them.

## Constraints

- `nix develop -c dune build` and `nix develop -c dune runtest --force`
  must keep passing. There is no `autoresearch.checks.sh` yet; add one
  if you want regressions caught automatically per iteration.
- No new opam dependencies without a clear reason.
- Public APIs in `.mli` files should not silently widen.
- Preserve the Eta boundary called out in `AGENTS.md`: applications own
  state, Eta owns effect description and interpretation.

## What's been tried

(empty — populate as iterations accumulate. Note both wins and dead
ends, especially for runs that get reverted; the JSON line + ASI is
otherwise the only durable record.)

## Notes / hints for the next agent

- The H2 warmup itself (first request) is reported to succeed; only the
  *kept-alive* path stalls. Watching for unsent WINDOW_UPDATEs, missing
  SETTINGS ACK, half-closed streams that never get cleaned up, or a
  stream-id allocator that wraps incorrectly are good first hypotheses.
- 44 ms is suspiciously close to a round figure. Look for any literal
  delay (`Duration.ms 40` etc.), a default Nagle/cork toggle, or a
  retry that always fires once before succeeding. Search across
  `packages/eta-http/` and `packages/eta/`.
- `Eta.Effect.timeout_as` uses `Eta.Duration.ms` — if you bump the
  timeout for diagnostic runs, do it via `ETA_PERF_TIMEOUT_MS` rather
  than editing `run.ml`.
- The Go helper is rebuilt every iteration into a temp dir; that is
  ~1–2 s of overhead you can skip by caching, but it is not currently
  the bottleneck.
- If you need finer-grained signal, add `METRIC` lines for per-phase
  timings (connect, handshake, request write, response read) inside
  `run.ml` and surface them through `autoresearch.sh`.
