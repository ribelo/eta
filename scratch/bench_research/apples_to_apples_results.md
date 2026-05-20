# Apples-to-Apples Effet Overhead Results

Command:

```sh
nix develop -c dune exec scratch/bench_research/apples_to_apples.exe
```

Machine: AMD Ryzen 9 9950X, OCaml 5.4.1. Samples: 20.
Workloads: 100k bind operations and 100k typed failure/catch operations.

## Raw Results

| Workload | Mean wall | Min wall | Minor words | Major words |
| --- | ---: | ---: | ---: | ---: |
| direct loop 100k | 35.1 us | 34.8 us | 0 | 0 |
| direct closure-bind 100k | 88.4 us | 87.0 us | 0 | 0 |
| mini interpreter bind 100k, prebuilt | 486.1 us | 390.1 us | 262,144 | 26 |
| mini interpreter bind 100k, build+run | 4.41 ms | 3.99 ms | 655,358 | 300,024 |
| mini interpreter fail/catch 100k, prebuilt | 333.3 us | 303.0 us | 1,048,568 | 33 |
| mini interpreter fail/catch 100k, build+run | 305.5 us | 304.9 us | 1,048,566 | 24 |
| Eio setup only | 51.9 us | 42.0 us | 299 | 255 |
| Effet setup + pure | 44.7 us | 40.1 us | 252 | 243 |
| Effet pure, reused runtime | 0.75 us | timer floor | 0 | 0 |
| Effet bind 100k, prebuilt | 7.16 ms | 6.44 ms | 655,357 | 262,095 |
| Effet bind 100k, build+run | 12.30 ms | 11.82 ms | 917,499 | 558,743 |
| Effet fail/catch 100k, prebuilt | 1.72 ms | 1.66 ms | 2,097,144 | 169 |
| Effet fail/catch 100k, build+run | 1.66 ms | 1.65 ms | 2,097,147 | 186 |

## Ratios

| Comparison | Ratio | Per operation |
| --- | ---: | ---: |
| Effet bind vs minimal interpreter, prebuilt | 14.7x | 71.6 ns vs 4.9 ns |
| Effet bind vs minimal interpreter, build+run | 2.8x | 123.0 ns vs 44.1 ns |
| Effet fail/catch vs minimal interpreter, prebuilt | 5.2x | 17.2 ns vs 3.3 ns |
| Effet fail/catch vs minimal interpreter, build+run | 5.4x | 16.6 ns vs 3.1 ns |
| Effet setup+pure vs Eio setup | within noise | 44.7 us vs 51.9 us |

## Interpretation

The fair denominator is the mini interpreter, not the raw direct loop. Direct
OCaml is the lower bound, but it does not carry an effect AST or an interpreter.

Against a same-shape minimal interpreter, Effet costs:

- about 15x for pure bind interpretation when the program is already built;
- about 3x when program construction is included;
- about 5x for typed fail/catch;
- no measurable extra setup cost over Eio setup in this lab.

The absolute per-operation costs are still small: roughly 72 ns per interpreted
prebuilt bind and 17 ns per fail/catch on this machine. The allocation gap is
more important than the raw time gap: Effet bind interpretation allocates about
2.5x the minor words of the mini interpreter in the prebuilt bind path, and
typed fail/catch allocates about 2x.

