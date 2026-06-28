# Eta-5zo completion audit

Source requirement: `.backlog/Eta-5zo.md`.

| # | Requirement | Evidence | Verdict |
| --- | --- | --- | --- |
| 1 | Raw Eio only at I/O leaves; non-I/O concurrency/batching/retry/lifecycle built from Eta primitives. | `rg` for `Eio.Stream`, `Eio.Fiber`, `take_nonblocking`, `while true`, `fork_daemon` over eta-otel returns no matches. Remaining eta-otel `Eio.*` references are constructor inputs, HTTP POST leaf, `Eio.Time.now`, and `Eio.Switch.run` around the HTTP leaf. | Proven. |
| 2 | Exercise Eta primitives in real use. | `eta_otel.ml` uses `Stream.merge`, `Stream.flat_map_par`, `Mailbox.to_batch_stream`, `Effect.acquire_release`, `Effect.retry`, `Effect.timeout`, `Effect.race`, `Effect.Private.daemon`, `Resource.t`, `Effect.named`, `Effect.annotate`, and `Capabilities.clock`; `Stream.Drain_counter` covers non-polling flush. `Effect.island` and `Effect.blocking` are documented as not applicable: encoding does not justify CPU offload and transport is Eio TCP. | Proven. |
| 3 | Self-instrumented without recursive export. | `test_self_spans_do_not_reenter_export` verifies self spans are recorded in the private tracer and not sent in the exported body. | Proven. |
| 4 | Tutorial document with sections mapped to primitives. | `docs/tutorial-eta-otel.md` covers explicit dependencies, mailbox/stream pipeline, cached `Resource.t`, backpressure, `Drain_counter` flush, retry/timeout/race, and self-observation. `tutorial_outline.md` records the planned structure. | Proven. |
| 5 | Benchmark throughput/latency at-or-better than hand-rolled exporter. | Encoder repeat: `bench/results/eta-otel-encoder-repeat-current.json` and `current_encoder_repeat.txt`. E2E same-file local collector comparison: `exporter_e2e_baseline_head.txt` vs `exporter_e2e_after_rebuild.txt`; rebuilt submit+flush wins on span/log/metric means and throughput. Quick gate: `bench/results/eta-5zo-quick-current.json`. | Proven. |
| 6 | Existing eta-otel tests pass; adversarial tests cover required failures. | `dune runtest packages/eta-otel --force` passes 26 tests, including network partition, malformed response, slow collector timeout, backpressure overflow, shutdown, and self-recursion tests. | Proven. |
| 7 | OTLP wire shape unchanged. | Encoder smoke and live OTLP tests pass; no protocol dependency or path changes are part of the rebuild. | Proven. |
| 8 | Research artifacts produced. | `current_inventory.md`, `external_exporter_analysis.md`, `otlp_inventory.md`, `eta_api_gap_analysis.md`, benchmark baselines, `tutorial_outline.md`, and `architecture_decisions.md` exist under `.scratch/eta_otel_rebuild/`. | Proven. |
| 9 | ADRs for ingestion, actor model, backpressure, recursion, shutdown, transparent cost. | `architecture_decisions.md` contains ADR-1 through ADR-6 for exactly these topics. | Proven. |
| 10 | Readable reference example. | Public API documented in `eta_otel.mli`; README and tutorial explain the implementation path; implementation has named sections and uses Eta primitives directly instead of hidden raw loops. | Proven by inspection. |
| 11 | No dependency on dead OxCaml-native assumptions. | Current eta-otel packages and tutorial have no split AST, portable Effect.t, H3 transport, Cause.Portable, or Portable_ws_deque dependency. The ticket and historical journal mention those only as rejected/dead context. | Proven. |

Final gate evidence:

- `dune runtest packages/eta packages/eta-stream packages/eta-schema packages/eta-otel packages/ppx_eta --force` passed: eta 133, eta-stream 17, eta-schema, eta-otel 26, ppx_eta 2.
- `dune runtest --force` passed.
- `git diff --check` passed.
- Current benchmark JSON artifacts validate with `python3 -m json.tool`.
