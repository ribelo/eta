# Eta and Jane Street incremental performance

## Result

Jane Street Incremental and `Incr_map` were faster in every matched workload.
The difference was large for scalar signals and extreme for keyed maps.

The main table compares Eta Signal with Incremental, and
`Eta_signal_map.Keyed.mapi` with `Incr_map.mapi'`. These are the closest public
API matches. Eta Crux results are listed separately because a Crux advancement
does more work than an Incremental stabilization.

## Matched Signal results

The reported time is the median of three process-run means. Each process run
contains nine timed samples. The range is the minimum and maximum process-run
mean.

| Workload | Eta Signal | Incremental | Eta / Jane |
|---|---:|---:|---:|
| Changed scalar, 1 map | 11.00 us (10.89-11.03) | 32.8 ns | 335x |
| Changed scalar, 10 maps | 14.66 us (14.58-14.68) | 96.8 ns | 152x |
| Changed scalar, 100 maps | 72.34 us (71.60-72.50) | 990 ns | 73.1x |
| Cutoff before 10 dependents | 11.63 us (11.57-11.67) | 31.5 ns | 369x |
| Dynamic branch switch | 21.33 us (20.94-21.65) | 126 ns | 170x |

Steady-state allocation was:

| Workload | Eta Signal | Incremental |
|---|---:|---:|
| Changed scalar, 1 map | 8,795 words | below measurement resolution |
| Changed scalar, 10 maps | 12,287 words | below measurement resolution |
| Changed scalar, 100 maps | 49,043 words | below measurement resolution |
| Cutoff before 10 dependents | 9,780 words | below measurement resolution |
| Dynamic branch switch | 16,339 words | 43 words |

Both cutoff validation probes stopped before the ten dependent maps.

## Matched keyed-map results

Both packages received a persistent map with the same key count. The data-change
workload changed one existing key. The child-change workload changed one stable
child source without changing the input map. Each operation stabilized once.
The final output map had the same cardinality and changed value.

Eta used `Eta_signal_map.Keyed.mapi`. Jane Street used `Incr_map.mapi'`, not the
cheaper pure `mapi`, because both matched operators create one stable child
signal for each key.

| Workload | Eta Signal Map | `Incr_map` | Eta / Jane |
|---|---:|---:|---:|
| One data change, 10k keys | 13.94 ms | 264 ns | 52,736x |
| One data change, 100k keys | 301 ms | 320 ns | 942,749x |
| One child-only change, 10k keys | 60.90 ms | 92.1 ns | 661,104x |
| One child-only change, 100k keys | 1.723 s | 106 ns | 16,199,579x |

Allocation was:

| Workload | Eta Signal Map | `Incr_map` |
|---|---:|---:|
| One data change, 10k keys | 2,571,401 words | 180 words |
| One data change, 100k keys | 25,106,642 words | 228 words |
| One child-only change, 10k keys | 6,993,791 words | 78 words |
| One child-only change, 100k keys | 72,998,406 words | 102 words |

The Eta validation probe reported exactly one keyed child visit. The Incremental
probe recomputed fewer than 32 graph nodes. Therefore, the matched workload did
not intentionally execute all child callbacks on either side. This benchmark
does not identify what internal work accounts for the Eta time and allocation.

## Eta Crux context

The exploratory direct-root benchmark measured about 36 us for a one-map
changed advancement, 49 us for a 100-map advancement, and 37 us for a dynamic
branch switch. These are framework-level results: each Crux operation includes
action admission, root transaction publication, and post-commit handling.
Incremental has no matching operation, so this report does not present those
values as an apples-to-apples ratio.

## Method

- Eta commit: `5614fa66`
- Incremental: `v0.18~preview.130.91+190`, source commit
  [`31eb755`](https://github.com/janestreet/incremental/tree/31eb755facdfcaaf4ccbae55dffd829f7c7278f9)
- `Incr_map`: `v0.18~preview.130.91+190`, source commit
  [`07e7d3c`](https://github.com/janestreet/incr_map/tree/07e7d3ca75fe1aa855595cf617fd205f9d419653)
- Compiler: OCaml `5.2.0+ox`, without Flambda
- Build: native Dune `release` profile
- Host: AMD Ryzen 9 9950X
- Execution: pinned to logical CPU 2 with the `performance` governor
- Repetitions: three fresh processes, nine timed samples per workload
- Calibration: batches of at least 0.5 seconds
- Timing: wall time divided by the operation count
- Allocation: `Gc.counters` delta divided by the operation count

For Eta Signal, all updates in one timed sample ran inside one long-lived
`Eta.Runtime.run`. Incremental used one ordinary loop for the same sample. Each
logical operation set one source and stabilized once. The existing observer was
read and validated after each calibrated batch. Runtime entry, graph
construction, observer construction, initial stabilization, validation probes,
and teardown were not repeated per operation.

Callbacks used by the timed graph were pure. Cutoff, recompute-count, keyed
child-visit, output, and cardinality checks ran outside the timed region.

Incremental documents its source, observer, cutoff, and stabilization model in
its
[public interface](https://github.com/janestreet/incremental/blob/31eb755facdfcaaf4ccbae55dffd829f7c7278f9/src/incremental_intf.ml).
`Incr_map` documents `mapi'` in its
[public interface](https://github.com/janestreet/incr_map/blob/07e7d3ca75fe1aa855595cf617fd205f9d419653/src/incr_map_intf.ml).
Eta semantics are defined by
[`eta_signal.mli`](../../../../lib/signal/eta_signal.mli) and
[`eta_signal_map.mli`](../../../../lib/signal_map/eta_signal_map.mli).

## Scope

This report covers steady-state scalar propagation, cutoff, dynamic branch
replacement, one keyed data change, and one keyed child change. It does not
cover graph construction time, memory residency, teardown, concurrent writers,
serialized Crux transport, or multi-domain throughput.

Raw Signal samples are in `signal/results/run1.csv`,
`signal/results/run2.csv`, and `signal/results/run3.csv`.
`signal/results/summary.json` contains the aggregate values. The exact harness
is `signal/compare.ml`. Exploratory Crux evidence is under `crux/`.
