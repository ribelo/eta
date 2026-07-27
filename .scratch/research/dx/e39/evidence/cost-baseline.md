# DX-E39 Cost Baseline — BEFORE

## Pre-registered comparison

The primary row is `effect.construction.map_bind_preserve`: 100,000 iterations,
each constructing one `Map`, one `Bind`, and one preserve-backed
`Effect.uninterruptible` wrapper. `effect.construction.map_bind` is the no-preserve
control; `effect.construction.preserve` isolates preserve-backed wrapping.

For the S comparison:

- allocated words = `minor_words + major_words - promoted_words` from
  `Gc.counters`, avoiding both collection-boundary sampling and double-counted
  promotion;
- time = median `wall_ns` after discarding the first of eleven samples as warm-up;
- delta = `(S - master) / master * 100` (negative is an improvement);
- the raw `major_words` series remains in JSON, but is not added to
  `minor_words`, because promoted minor allocations would otherwise be counted
  twice.

The assignment's threshold remains unchanged: at least 10% construction
overhead makes cost a first-class decision argument.

## Command and revision

```text
nix develop -c bash bench/run.sh \
  --filter '^effect.construction.' \
  --out .scratch/research/dx/e39/evidence/cost-before.json
commit=ba1275f40a0d8178413750a7f6eb6e6378b34295
dirty=false
```

The benchmark source and the dishonesty probe were committed before this run.
Raw samples and the machine envelope are in `cost-before.json`.

## Machine

- Linux 7.1.3
- AMD Ryzen 9 9950X 16-Core Processor
- 32 logical CPUs
- OCaml 5.2.0+ox
- Dune 3.22.2

## BEFORE values

| Row | Allocated words | Median wall ns | Mean wall ns |
| --- | ---: | ---: | ---: |
| `map_bind` | 600,014 | 261,545 | 324,704 |
| `preserve` | 1,600,014 | 2,964,973 | 3,006,437 |
| `map_bind_preserve` **(primary)** | **2,200,014** | **6,357,551** | 6,442,525 |

All eleven allocation samples are identical within each row. The map/bind row is
the negative control; the preserve-bearing rows discriminate the metadata removed
by S. Raw counter and time samples are retained so the comparison does not depend
on this summary or its rounding.
