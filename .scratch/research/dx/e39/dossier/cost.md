# Construction cost evidence

## Protocol

Both sides used the same committed benchmark, Nix OxCaml shell, machine, and
100,000-layer workloads. Eleven samples were taken; timing is the median after
discarding the first warm-up sample. Allocated words are
`minor_words + major_words - promoted_words` from `Gc.counters`, avoiding
promotion double-counting.

- Raw BEFORE: [`../evidence/cost-before.json`](../evidence/cost-before.json)
- Raw S: [`../evidence/cost-after-s.json`](../evidence/cost-after-s.json)
- Pre-registered method: [`../evidence/cost-baseline.md`](../evidence/cost-baseline.md)
- Calculation narrative: [`../evidence/cost-measurement.md`](../evidence/cost-measurement.md)
- Machine: Linux 7.1.3, AMD Ryzen 9 9950X, 32 logical CPUs, OCaml 5.2.0+ox,
  Dune 3.22.2

## Results

| Row | BEFORE words | S words | Word delta | BEFORE median ns | S median ns | Time delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `map_bind` control | 600,014 | 600,014 | 0.00% | 261,545 | 259,399 | -0.82% |
| `preserve` | 1,600,014 | 800,014 | **-50.00%** | 2,964,973 | 235,438 | **-92.06%** |
| `map_bind_preserve` primary | 2,200,014 | 1,400,014 | **-36.36%** | 6,357,551 | 2,879,977 | **-54.70%** |

The deterministic primary allocation delta is 800,000 words: eight words per
preserve layer (six footprint fields plus record header, and the removed
`Custom.footprint` field). The unchanged control isolates the removed metadata.
The pre-registered 10% threshold fires decisively.

This measurement compares BEFORE with S, as required. It establishes the cost
of the footprint mechanism shared by neither final endpoint; it does **not**
measure an R-over-S delta and therefore cannot by itself select R over S.
