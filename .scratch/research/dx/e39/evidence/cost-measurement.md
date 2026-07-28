# DX-E39 Cost Measurement — BEFORE vs Endpoint S

## Protocol

Both runs used the committed `effect.construction.*` benchmark, the same Nix
OxCaml shell, compiler/profile, and machine. Each row constructs 100,000 layers
and records eleven samples. Allocation is
`minor_words + major_words - promoted_words` from `Gc.counters`. Timing uses the
median after discarding the first sample as warm-up, exactly as pre-registered in
`cost-baseline.md`.

- BEFORE: `cost-before.json`, production tree before S, `dirty=false`
- S: `cost-after-s.json`, commit
  `6c51b9e305d3d1cb492bdd69f3d0784d134c0ca9`, `dirty=false`
- Machine: Linux 7.1.3, AMD Ryzen 9 9950X, 32 logical CPUs,
  OCaml 5.2.0+ox, Dune 3.22.2

Delta is `(S - BEFORE) / BEFORE * 100`; negative is improvement.

## Results

| Row | BEFORE words | S words | Word delta | BEFORE median ns | S median ns | Time delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `map_bind` control | 600,014 | 600,014 | **0.00%** | 261,545 | 259,399 | -0.82% |
| `preserve` | 1,600,014 | 800,014 | **-50.00%** | 2,964,973 | 235,438 | **-92.06%** |
| `map_bind_preserve` primary | 2,200,014 | 1,400,014 | **-36.36%** | 6,357,551 | 2,879,977 | **-54.70%** |

Allocation is deterministic across all eleven samples in every row. The control
is allocation-identical and timing-neutral, while both preserve-bearing rows
move strongly in the predicted direction. The primary row removes 800,000 words,
exactly eight words per preserve layer: the six-field footprint record plus its
header (seven words), and the removed `Custom.footprint` field (one word).

## Threshold and prediction

The pre-registered 10% threshold fires: the primary workload allocates 36.36%
fewer words on S (equivalently, BEFORE imposed 57.14% overhead relative to S).
Cost is therefore a first-class endpoint argument.

The sealed prediction was 10–25% fewer allocated words and 5–15% faster. The
observed primary deltas are larger: **36.36% fewer words** and **54.70% faster**.
Direction and threshold were correct; both predicted brackets were misses.
