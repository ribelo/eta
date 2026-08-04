# Eta Signal V1 baseline

Date: 2026-08-04

Eta commit: `6b98144e91e657594e72c6df1da270c62e18dc9d`

## Counting method

The counts include every physical line in each tracked `.ml` and `.mli` file.
Blank lines and comments are included.

The production count includes these paths:

- `lib/signal/`
- `lib/signal_map/`
- `lib/crux/`

The production count excludes each `bench/` directory.

The full scoped count includes production, benchmarks, and these test paths:

- `test/signal/`
- `test/signal_map/`
- `test/crux/`

The TSV files in `baseline/loc/` contain one row for each counted file.

## Eta counts

| Scope | Files | Lines |
|---|---:|---:|
| Eta Signal production | 33 | 14,628 |
| Eta Signal Map production | 5 | 768 |
| Eta Signal and Signal Map production | 38 | 15,396 |
| Eta Crux production | 19 | 6,282 |
| Complete production scope | 57 | 21,678 |
| Complete scoped OCaml source | 126 | 50,388 |

The final complete production count must not exceed 21,678 lines.
The final complete scoped source count must not exceed 50,388 lines.

## Jane Street reference counts

The benchmark uses Jane Street Incremental for scalar workloads.
It uses Jane Street `Incr_map.mapi'` for keyed-map workloads.
There is no “BAP-incr” implementation in the benchmark.

| Reference | Commit | Counted path | Files | Lines |
|---|---|---|---:|---:|
| Incremental | `31eb755facdfcaaf4ccbae55dffd829f7c7278f9` | `src/**/*.ml{,i}` | 77 | 9,891 |
| Incr_map | `07e7d3ca75fe1aa855595cf617fd205f9d419653` | `src/**/*.ml{,i}` | 3 | 3,643 |
| Combined reference | the commits above | both paths | 80 | 13,534 |

Eta Signal and Signal Map currently use 15,396 lines.
The matching Jane Street libraries use 13,534 lines.
Eta therefore starts 1,862 lines, or 13.8%, larger.

Eta Crux has no matched Incremental operation or source package.
Its 6,282 lines stay visible in the complete production gate.

## Performance gate

The benchmark contains two matched groups:

- Eta Signal against Incremental
- Eta Signal Map against Incr_map

Each final Eta workload must be faster than its saved Eta baseline.
Each final Eta workload must be no slower than `1.20×` its matching Jane Street workload.

The raw baseline CSV files and their summary belong in `baseline/benchmark/`.
The benchmark uses three fresh processes and nine samples for each workload.
