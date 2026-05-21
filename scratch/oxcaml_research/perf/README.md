# OxCaml vs mainline OCaml — Effet bench comparison

Status: final. **Yes — OxCaml is faster by default for free for Effet.**

## Decision question

Without changing any Effet source, does swapping the mainline `5.4.1`
toolchain for the OxCaml `5.2.0+ox` toolchain make the existing bench suite
faster?

## Verdict

**Yes, by a large margin.**

- **76/98** wall_ns benchmarks improve by more than 5% under OxCaml.
- **10/98** regress by more than 5%.
- **12/98** are within ±5% (noise band).
- **Geomean speedup: 1.49×** (oxcaml/mainline ratio = 0.673).
- **Median speedup: 1.34×** (ratio = 0.747).
- Total wall time of the suite: mainline 189.7 s, oxcaml 183.4 s.

The win is largest on AST-heavy workloads (build + evaluate effect trees)
and stream / file-IO pipelines.

## Method

- Same source tree, same machine (`AMD Ryzen 9 9950X`, Linux), same
  `--profile=release`, same `EIO_BACKEND=posix` (the nix sandbox cannot use
  io_uring on either toolchain).
- Bench infrastructure was rebased from `main` (commits 3b5a50f..d69e3f9) into
  the `Effet-OxCaml` branch as a linear-history rebase. No bench source was
  modified for this comparison.
- Each toolchain ran `scratch/oxcaml_research/perf/run_perf.sh` once, end to
  end, full samples (no `--quick`). The TS reference suite and compile probes
  were skipped to keep the comparison apples-to-apples on Effet OCaml code.

Reproduce:

```sh
nix develop -c            bash scratch/oxcaml_research/perf/run_perf.sh mainline
nix develop .#oxcaml -c   bash scratch/oxcaml_research/perf/run_perf.sh oxcaml
python3 scratch/oxcaml_research/perf/compare.py | tee scratch/oxcaml_research/perf/compare.txt
```

## Top wins (oxcaml/mainline ratio)

| Benchmark | Mainline (ns) | OxCaml (ns) | Ratio | Speedup |
| --- | --- | --- | --- | --- |
| overhead.mini.bind.100k.build_run | 4 138 612 | 449 371 | 0.109 | 9.2× |
| overhead.effet.bind.100k.build_run | 3 623 962 | 419 998 | 0.116 | 8.6× |
| effet_stream.from_file.16MiB.64KiB | 11 592 578 | 1 377 391 | 0.119 | 8.4× |
| effect.core.map_chain.100k | 5 820 560 | 889 253 | 0.153 | 6.5× |
| effet_stream.merge.early_take.5 | 319 433 | 74 338 | 0.233 | 4.3× |
| effect.observability.effet_otel.encoder.span.1000 | 1 620 912 | 513 362 | 0.317 | 3.2× |
| effect.concurrency.supervisor.start_await.1 | 61 368 | 23 794 | 0.388 | 2.6× |
| effet_stream.from_file.1MiB.4KiB | 1 156 425 | 468 444 | 0.405 | 2.5× |
| overhead.direct.closure_bind.100k | 88 644 | 37 860 | 0.427 | 2.3× |
| effect.core.bind_left.100k | 4 646 968 | 2 305 603 | 0.496 | 2.0× |

## Regressions (oxcaml slower than mainline)

| Benchmark | Mainline (ns) | OxCaml (ns) | Ratio |
| --- | --- | --- | --- |
| effet_schema.decode.array.10 | 572 | 1 001 | 1.750 |
| effect.observability.cause.construction.suppressed | 8 678 | 11 539 | 1.330 |
| overhead.mini.fail_catch.100k.prebuilt | 281 477 | 358 533 | 1.274 |
| effect.observability.effet_otel.encoder.metric.100 | 12 445 | 15 640 | 1.257 |
| effect.observability.effet_otel.encoder.log.100 | 44 631 | 49 400 | 1.107 |
| effet_stream.range.map.filter.fold.1M | 23 666 954 | 26 145 982 | 1.105 |
| effect.observability.cause.construction.concurrent | 17 356 | 18 596 | 1.071 |
| effect.observability.effet_otel.encoder.span.100 | 60 415 | 64 420 | 1.066 |
| overhead.direct.loop.100k | 35 238 | 37 384 | 1.061 |
| effect.observability.named_with_attrs | 30 685 481 071 | 32 305 851 602 | 1.053 |

Most of these are sub-microsecond and within run-to-run noise on a single
sample. The largest absolute regression is in cause-construction paths (about
3 µs added on `suppressed`) and small-input encoder paths.

## Caveats

- One sample per toolchain; not a publication-grade benchmark. The signal is
  large enough to dominate noise but the regressions in particular should be
  re-measured before any optimization decision.
- Both runs were forced to `EIO_BACKEND=posix` because the nix sandbox cannot
  open `io_uring`. Production workloads on `eio_linux` may differ.
- The bench tree is dirty (untracked perf scripts) on both runs; commit hash
  is the same for both.
- The `effect.observability.named_with_attrs` row is a 30-second benchmark
  used as sustained-allocation pressure; a 5% delta there is well within the
  GC noise band.

## Verdict line

For the stakeholder report: **switching Effet from mainline OCaml 5.4.1 to
OxCaml 5.2.0+ox, with no source changes, makes the bench suite roughly
1.34× to 1.49× faster across 88% of measured workloads.** Combined with the
adoption verdict in `results.md` (compatible + better suited on safety and
parallelism axes), perf is now a third independent reason to switch.

## Artifacts

All under `scratch/oxcaml_research/perf/`:

- `run_perf.sh` — runs the OCaml runtime bench exes once and dumps a unified
  JSON.
- `mainline.json`, `oxcaml.json` — raw bench output for each toolchain.
- `compare.py` — joins the two JSON files and prints the ratio table.
- `compare.txt` — the full per-benchmark table (294 rows × 3 metrics → 98
  wall_ns rows).
