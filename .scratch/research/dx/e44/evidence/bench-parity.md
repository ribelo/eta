# Runtime-observability benchmark parity

> Historical first-pass evidence. This run omitted the batch paths later found
> to allocate twice per point, so its broad "all changed paths" verdict is
> superseded by `bench-followup-pairs/README.md`. The measurements below remain
> unchanged as provenance for the single-point follow-up.

## Exact command

The required command was run before and after the split:

```sh
nix develop -c bash bench/run.sh --quick
```

Both runs stopped in the unchanged TypeScript comparison workload before the
result envelope was written because `Effect.with_scope` is unavailable. The
matching failures are `bench-before-failure.txt` and
`bench-after-failure.txt`. E44 did not change that adjacent benchmark.

## Focused watchlist

The affected native watchlist was therefore measured directly. A baseline tree
was materialized from pre-implementation commit `31c4d93a`; both executables
were built through the Nix/OxCaml shell. Fifteen before/after pairs were run
with three samples per row, alternating execution order between pairs:

```text
EIO_BACKEND=posix <before>/runtime_observability.exe --samples 3
EIO_BACKEND=posix <after>/runtime_observability.exe  --samples 3
```

Raw results are under `bench-pairs/`; `bench-parity.csv` contains paired-median
and pooled deltas across 45 samples per side.

For the ten rows whose execution path changed, the largest pooled wall-time
regression is **+1.936%** (`in_memory_tracer.no_auto`). Every other affected
regression is smaller than 2%:

| Changed path | Pooled wall delta | Allocation delta |
| --- | ---: | ---: |
| noop tracer, no auto | -0.205% | 0 |
| noop tracer, auto | +1.111% | 0 |
| in-memory tracer, no auto | +1.936% | 0 |
| in-memory tracer, auto | +1.382% | 0 |
| named span only | +1.074% | 0 |
| named with attrs | -3.107% | -109,994 words |
| noop logger | -0.104% | -20,000 words |
| in-memory logger | +0.187% | -20,000 words |
| noop meter | -0.586% | -100,000 words |
| in-memory meter | -0.513% | -100,000 words |

The improvements larger than 2% are explained by verified removal of
intermediate allocations: captured optional span parameters no longer allocate
per interpretation, log admission no longer returns an option block, and metric
points are constructed only after admission without an intermediate SDK record.
No changed row allocates more than baseline.

Unchanged controls still show host noise beyond 2% in both directions (for
example OTEL log encoding +8.870% and cause construction -4.499%). Those rows do
not execute the split seam; they are retained in the CSV rather than discarded.
Alternating pairs prevents their temporal drift from being misreported as an
E44 path regression.

**Verdict:** affected watchlist regressions are within the required 2% noise
bound, with deterministic allocation parity or improvement.
