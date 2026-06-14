# H1 latency ideas backlog (ordered by expected impact)

Proven playbook from the H2 latency session. Apply the same patterns to H1.

## 1. Remove per-op timeout forks (THE big lever — H2 gave −22 to −38% p99)
H1 `h1_server_connection.ml` arms `Eio.Time.with_timeout` / `fork_daemon`+sleep
per operation, each forking a fiber + Zzz timer + promise for a timeout that
almost never fires. Targets:
- **request-head read timeout** (`read_request_head_with_timeout` ~1093, plus a
  per-request `Fiber.first` at ~1054) — likely the biggest H1 win, analogous to
  the H2 handler-switch + per-request Fiber.first removal.
- **handler timeout** (~873, ~1042-1055) — convert to per-connection watchdog +
  `Cancel.sub` deadline slot (mirror the H2 handler watchdog).
- **write timeout** (~173) — per-connection watchdog + write_watch slot (mirror
  H2 #5; gave −22% p99 / −39% RSS / +10% rps across all endpoints).
- **body read timeout** (~369) — sync-skip: arm only if the read didn't complete
  synchronously (mirror H2 #4; gave echo −38% p99 / −33% RSS).

Note: H1's connection model differs from H2 (no owner-loop command queue; the
handler runs more directly). Study the actual H1 fiber structure before porting
the watchdog — it may be simpler (a single request-at-a-time keep-alive loop).

## 2. Gate request_metrics on metrics_enabled (H2 #8)
`request_metrics` (~1018) gated only on `enable_otel`. Add
`&& Eta.Runtime.metrics_enabled rt` (accessor already on master). Skips
per-request Semconv metric-attr building (string_of_int + list alloc) when no
meter installed.

## 3. Confirm/extend shared tracer gating
The shared `server_tracer.ml` `is_tracing_enabled` skip (#9) and
`annotate_all_lazy` (#7) already help H1. Verify the H1 path actually routes
through `server_tracer.request` and benefits; if it has its own span wiring,
apply the same gate.

## 4. Per-response allocation (H2 #2, #3, #11)
- Single-chunk fixed-body fast path (skip Bytes.concat copy).
- Share-on-unchanged header normalization.
- No-snprintf decimal writer for Content-Length / status (H1 response_write.ml
  already had add_decimal from the throughput session — verify it's used).

## 5. H1-specific: keep-alive request loop
H1 reuses a connection for many sequential requests. Check the per-request
setup/teardown in the keep-alive loop (buffer resets, request record alloc,
pending-buffer handling) for per-request overhead that the H2 per-stream path
doesn't have.

## Noise limitations
p99 geomean is noise-limited (~150-250µs from body-endpoint variance). Use p50 +
rps + RSS as corroborating signals. Re-run when one endpoint p99 is an outlier.
