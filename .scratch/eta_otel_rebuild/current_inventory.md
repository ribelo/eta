# Current eta-otel inventory

## Code shape

Baseline at commit 4174444 refactor: rename Effet to Eta.

| File | Lines |
| --- | ---: |
| packages/eta-otel/eta_otel.ml | 734 |
| packages/eta-otel/eta_otel.mli | 102 |
| packages/eta-otel/test/run.ml | 166 |
| packages/eta-otel/test/test_logger.ml | 150 |
| packages/eta-otel/test/test_metrics.ml | 236 |
| packages/eta-otel/test/test_tracer.ml | 303 |

## Raw Eio/concurrency surface in eta_otel.ml

Current exporter-owned mechanisms:

- HTTP leaf: Eio.Net.with_tcp_connect, Eio.Flow.copy_string, Eio.Flow.shutdown, Eio.Buf_read.of_flow, Eio.Buf_read.line.
- Time leaf: Eio.Time.now, Eio.Time.sleep.
- Queueing: three Eio.Stream.t queues, one each for spans, logs, metrics.
- Lifecycle: three Eio.Fiber.fork_daemon loops.
- Batching: manual take, take_nonblocking, fixed batch sizes 32/64/128.
- Flush: Atomic.in_flight polling with Eio.Time.sleep.
- State: mutable span table, mutable next_handle, mutable callbacks.

Only the HTTP/time leaves are acceptable as raw Eio in the target design. The
queueing, batching, daemon lifecycle, timeout, retry, and flush behavior must
move to Eta-owned effects or to a small Eta primitive if current Eta cannot
express the boundary.

## Baseline tests

Command:

export OPAMROOT=/home/ribelo/projects/ribelo/ocaml/Effet-OxCaml/.opam-oxcaml
eval $(opam env --switch=5.2.0+ox --set-switch)
dune runtest packages/eta-otel --force

Result:

- 20 eta-otel tests passed.
- Known OxCaml alerts appear from Domain.spawn in Eta blocking internals.

## Focused encoder baseline

The first focused encoder baseline was taken before repairing the repo-wide
benchmark fixtures. At that point the full benchmark runner still had stale
env-era targets. Those fixtures have since been migrated to explicit dependency
passing, so the focused encoder baseline is no longer a workaround for a broken
bench gate; it remains the apples-to-apples encoder denominator for eta-otel.

Command:

dune exec scratch/eta_otel_rebuild/baseline_encoder.exe

Result from scratch/eta_otel_rebuild/baselines/current_encoder_quick.txt:

span.100 wall_ns 101805 minor_words 0 major_words 0
span.1000 wall_ns 902891 minor_words 0 major_words 0
log.100 wall_ns 42915 minor_words 0 major_words 0
metric.100 wall_ns 11921 minor_words 0 major_words 0

The allocation counters are not useful in this scratch probe on the current
OxCaml setup; wall time is the usable baseline. The existing historical bench
JSON has allocation numbers, but it predates the Eta rename and is not an
apples-to-apples dirty-worktree baseline.

## Decision

Use the focused encoder baseline for the first rewrite comparison, and keep the
repo-wide quick bench as the hygiene gate. Current benchmark code uses
`explicit_deps`, and no current benchmark fixture depends on the removed
runtime environment argument.
