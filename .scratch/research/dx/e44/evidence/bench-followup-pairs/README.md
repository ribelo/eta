# Follow-up batch-metric benchmark

## Workload and comparison

The watchlist now includes three previously absent batch paths, each emitting
100,000 points as four descriptors interpreted 25,000 times:

- `metric_updates`;
- `metric_updates_lazy` with a producer returning the same four descriptors;
- `metric_updates` under a `Keep` interceptor.

The before executable is detached pre-split commit `fd27e518` with only the
committed `baseline-benchmark.patch` applied to add identical rows. The after
executable is the final follow-up tree. Both were built with Nix/OxCaml and run
with `EIO_BACKEND=posix`.

`run-pairs.sh` records 15 pairs with three samples per row and alternates which
executable runs first. `analyze.py` pools all 45 wall samples per side and also
computes a delta from each pair's three-sample median. `summary.csv` is the full
result, including unchanged controls.

## Batch results

| Path | Pooled median delta | Per-pair delta min / median / max | After-slower pairs | Allocation delta |
| --- | ---: | ---: | ---: | ---: |
| `metric_updates` | +0.873% | -16.041% / +1.186% / +10.178% | 10/15 | +4 words total |
| `metric_updates_lazy` | -16.110% | -22.036% / -15.735% / -3.820% | 0/15 | -199,995 words |
| `metric_updates` + `Keep` | -0.239% | -8.042% / +0.367% / +10.083% | 8/15 | +4 words total |

The four-word eager/intercept difference is constant over 100,000 emitted
points, so there is no per-point allocation regression. The lazy path improves
because the final seam no longer constructs a second effect and re-enters the
interpreter.

The allocation smoke files isolate the review finding:

| Path | Pre-split | Split before fix (`26dfcbe5`) | Final |
| --- | ---: | ---: | ---: |
| `metric_updates` | 4,000,943 | 5,100,946 | 4,000,947 |
| `metric_updates_lazy` | 4,200,942 | 5,100,946 | 4,000,947 |
| batch + `Keep` | 5,101,044 | 6,201,047 | 5,101,048 |

The final timestamp-aware producer constructs each point once and streams it to
the admitted emitter; there is no placeholder point, timestamp record copy, or
intermediate point list.

## Uncertainty statement

These are descriptive timings, not a confidence interval or a one-sided
performance bound. Fifteen pairs do not justify claiming that future runs are
bounded by either the pooled delta or the observed extrema. The per-pair spread
is material and includes both signs for the eager and interception cases.
Unchanged controls in the same run also drifted positively (for example noop
tracer pooled medians were +2.897% and +4.492%), confirming host/run noise. The
evidence establishes deterministic allocation parity and shows pooled batch
wall medians near parity, but it does not claim a statistical upper bound.
