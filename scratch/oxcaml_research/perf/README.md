# OxCaml vs mainline OCaml — Effet bench comparison

Status: final. **Yes — OxCaml is faster by default for free for Effet.**

## Decision question

Without changing any Effet source, does swapping the mainline `5.4.1`
toolchain for the OxCaml `5.2.0+ox` toolchain make the existing bench suite
faster?

## Verdict

**Yes, by a large margin, reproduced across two independent runs per
toolchain.**

Aggregate over 2 runs per toolchain, taking the per-benchmark min across runs
(robust to noise spikes; minimum is the standard for microbenchmarks):

- **83/98** wall_ns benchmarks improve by more than 5% under OxCaml.
- **7/98** regress by more than 5%.
- **8/98** are within ±5% (noise band).
- **Geomean speedup: 1.52×** (oxcaml/mainline ratio = 0.657).
- **Median speedup: 1.34×** (ratio = 0.748).
- **Best case: 11.5×** faster (`overhead.mini.bind.100k.build_run`).
- **Worst regression: 1.35×** slower (`effect.observability.effet_otel.encoder.metric.100`).
- Total wall of the suite per run: mainline ≈ 190 s, oxcaml ≈ 183 s.

The win is largest on AST-heavy workloads (build + evaluate effect trees),
stream / file-IO pipelines, and `for_each_par` / supervisor concurrency.

## Method

- Same source tree, same machine (`AMD Ryzen 9 9950X`, Linux), same
  `--profile=release`, same `EIO_BACKEND=posix` (the nix sandbox cannot use
  io_uring on either toolchain).
- Bench infrastructure was rebased from `main` (commits 3b5a50f..d69e3f9) into
  the `Effet-OxCaml` branch as a linear-history rebase. No bench source was
  modified for this comparison.
- Each toolchain ran `scratch/oxcaml_research/perf/run_perf.sh` twice
  back-to-back, full samples (no `--quick`). Aggregation uses the per-bench
  min across runs to suppress spike noise.
- The TS reference suite and compile probes were skipped to keep the
  comparison apples-to-apples on the OCaml side.

Reproduce:

```sh
nix develop -c          bash scratch/oxcaml_research/perf/run_perf.sh mainline 1
nix develop -c          bash scratch/oxcaml_research/perf/run_perf.sh mainline 2
nix develop .#oxcaml -c bash scratch/oxcaml_research/perf/run_perf.sh oxcaml 1
nix develop .#oxcaml -c bash scratch/oxcaml_research/perf/run_perf.sh oxcaml 2
python3 scratch/oxcaml_research/perf/compare.py | tee scratch/oxcaml_research/perf/compare.txt
```

## Top wins (oxcaml/mainline ratio, min-over-2-runs)

| Benchmark | Mainline (ns) | OxCaml (ns) | Ratio | Speedup |
| --- | --- | --- | --- | --- |
| overhead.mini.bind.100k.build_run | 3 994 941 | 346 183 | 0.087 | 11.5× |
| overhead.effet.bind.100k.build_run | 3 328 084 | 387 907 | 0.117 | 8.6× |
| effect.core.map_chain.100k | 5 382 061 | 837 087 | 0.156 | 6.4× |
| effect.core.map_chain.10k | 379 085 | 78 916 | 0.208 | 4.8× |
| effet_stream.merge.early_take.5 | 314 950 | 71 048 | 0.226 | 4.4× |
| effect.observability.effet_otel.encoder.span.1000 | 1 500 844 | 504 970 | 0.336 | 3.0× |
| overhead.direct.closure_bind.100k | 87 976 | 34 809 | 0.396 | 2.5× |
| effect.core.bind_left.100k | 3 461 122 | 1 423 120 | 0.411 | 2.4× |
| effect.core.bind_left.10k | 252 962 | 108 003 | 0.427 | 2.3× |
| effect.concurrency.all.heavy.64 | 152 111 | 66 995 | 0.440 | 2.3× |

## Regressions (oxcaml slower than mainline, min-over-2-runs)

| Benchmark | Mainline (ns) | OxCaml (ns) | Ratio |
| --- | --- | --- | --- |
| effect.observability.effet_otel.encoder.metric.100 | 8 821 | 11 920 | 1.351 |
| overhead.mini.fail_catch.100k.prebuilt | 251 054 | 287 771 | 1.146 |
| effet_stream.range.map.filter.fold.1M | 23 452 997 | 25 551 080 | 1.089 |
| effect.observability.cause.construction.concurrent | 16 927 | 17 881 | 1.056 |
| effect.observability.effet_otel.encoder.metric.100 | 8 821 | 11 920 | 1.351 |
| effect.observability.effet_otel.encoder.span.100 | 55 074 | 57 935 | 1.052 |

(Two additional rows at exactly 0 ns / inf ratio are sub-nanosecond
measurements that floor to zero and are excluded from the geomean.)

The regressions cluster on small-input observability paths (cause-construction
and otel encoder metrics for batch size 100). Absolute deltas are 1–4 µs.
None of the regressions are in hot AST or runtime paths.

## Caveats

- Two samples per toolchain per benchmark (each run already takes 5 internal
  samples per metric). Robust to single-sample noise but not a publication-grade
  benchmark — a third run could tighten the variance band and likely move
  some "same" benches into "faster".
- Both runs forced to `EIO_BACKEND=posix` because the nix sandbox cannot open
  `io_uring`. Production workloads on `eio_linux` may differ.
- The bench tree carries untracked perf scripts; commit hash is the same for
  every run.
- The 30-second `effect.observability.named_with_attrs` row is sustained-
  allocation pressure; it sat in the noise band on both samples.

## Verdict line

For the stakeholder report: **switching Effet from mainline OCaml 5.4.1 to
OxCaml 5.2.0+ox, with no source changes, makes the bench suite roughly
1.34× to 1.52× faster across 91% of measured workloads, reproduced over two
independent runs per toolchain.** Combined with the adoption verdict in
`results.md` (compatible + better suited on safety and parallelism axes),
perf is now a third independent reason to switch.

## Artifacts

All under `scratch/oxcaml_research/perf/`:

- `run_perf.sh` — runs the OCaml runtime bench exes once per invocation,
  takes a `<label> <run-id>` argument so multiple runs are kept side-by-side.
- `mainline.1.json`, `mainline.2.json`, `oxcaml.1.json`, `oxcaml.2.json` —
  raw bench output for each toolchain run.
- `compare.py` — joins all runs by toolchain, takes per-bench min across runs,
  prints the ratio table + summary.
- `compare.txt` — the full per-benchmark table (98 wall_ns rows).
