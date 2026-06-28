# Eta-5zo completion audit

Source requirement: local backlog record `Eta-5zo` (not tracked in Git).

| # | Requirement | Evidence | Verdict |
| --- | --- | --- | --- |
| 1 | Raw Eio only at I/O leaves; non-I/O concurrency/batching/retry/lifecycle built from Eta primitives. | `rg` for `Eio.Stream`, `Eio.Fiber`, `take_nonblocking`, `while true`, `fork_daemon` over eta-otel returns no matches. Remaining eta-otel `Eio.*` references are constructor inputs, HTTP POST leaf, `Eio.Time.now`, and `Eio.Switch.run` around the HTTP leaf. | Proven. |
| 2 | Exercise Eta primitives in real use. | `eta_otel.ml` uses `Stream.merge`, `Stream.flat_map_par`, `Mailbox.to_batch_stream`, `Effect.acquire_release`, `Effect.retry`, `Effect.timeout`, `Effect.race`, `Effect.daemon`, `Resource.t`, `Effect.named`, `Effect.annotate`, and `Capabilities.clock`; `Stream.Drain_counter` covers non-polling flush. Native island offload and blocking pools are not applicable: encoding does not justify CPU offload and transport is Eio TCP. | Proven. |
| 3 | Self-instrumented without recursive export. | `test_self_spans_do_not_reenter_export` verifies self spans are recorded in the private tracer and not sent in the exported body. | Proven. |
| 4 | Tutorial document with sections mapped to primitives. | `docs/tutorial-eta-otel.md` covers explicit dependencies, mailbox/stream pipeline, cached `Resource.t`, backpressure, `Drain_counter` flush, retry/timeout/race, and self-observation. `architecture_decisions.md` records the implementation decisions. | Proven. |
| 5 | Benchmark throughput/latency at-or-better than hand-rolled exporter. | Retained benchmark evidence: `bench/results/eta-otel-encoder-repeat-current.json` and `bench/results/eta-5zo-quick-current.json`. The E2E same-file local collector comparison was transient scratch output and is not retained in Git. | Partially retained. |
| 6 | Existing eta-otel tests pass; adversarial tests cover required failures. | `nix develop -c dune runtest test/otel --force` covers network partition, malformed response, slow collector timeout, backpressure overflow, shutdown, and self-recursion tests. | Proven. |
| 7 | OTLP wire shape unchanged. | Encoder smoke and live OTLP tests pass; no protocol dependency or path changes are part of the rebuild. | Proven. |
| 8 | Research artifacts produced. | Durable retained artifacts are `architecture_decisions.md`, this completion audit, and the retained benchmark baselines. Earlier inventory and exporter-analysis scratch notes were transient and are not retained in Git. | Partially retained. |
| 9 | ADRs for ingestion, actor model, backpressure, recursion, shutdown, transparent cost. | `architecture_decisions.md` contains ADR-1 through ADR-6 for exactly these topics. | Proven. |
| 10 | Readable reference example. | Public API documented in `eta_otel.mli`; README and tutorial explain the implementation path; implementation has named sections and uses Eta primitives directly instead of hidden raw loops. | Proven by inspection. |
| 11 | No dependency on dead OxCaml-native assumptions. | Current eta-otel packages and tutorial have no split AST, portable Effect.t, H3 transport, Cause.Portable, or Portable_ws_deque dependency. The ticket and historical journal mention those only as rejected/dead context. | Proven. |

Final gate evidence:

- `nix develop -c dune runtest --force`
- `git diff --check`
- Current benchmark JSON artifacts validate with `python3 -m json.tool`.
