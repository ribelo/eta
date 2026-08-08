# Eta Signal performance comparison

Date: 2026-08-08

## Result

The current public `eta_signal` and `eta_signal_map` operations are not
performance competitive with Incremental and `Incr_map`.

Every matched wall-time row failed the frozen `1.20` limit in all three process
pairs. Eta Signal was `8.98` to `37.12` times slower. Eta Signal Map was
`386.14` to `226,230.89` times slower.

This report records measurements only. It does not diagnose or optimize the
implementation.

## Compared versions

| Component | Version |
|---|---|
| Eta | commit `6f4c5cf7` with a clean worktree |
| Incremental | commit `31eb755facdfcaaf4ccbae55dffd829f7c7278f9` |
| `Incr_map` | commit `07e7d3ca75fe1aa855595cf617fd205f9d419653` |
| OxCaml | `5.2.0+ox` |
| Dune | `3.22.2` |

The installed Incremental and `Incr_map` packages both report version
`v0.18~preview.130.91+190`.

## Method

The run used the frozen
[comparison harness](../../../bench/signal_compare/compare.ml) with this
command:

```sh
PROCESSES=3 SAMPLES=9 CPU=2 \
  bash bench/signal_compare/run.sh /tmp/eta-signal-incremental-6f4c5cf7
```

The executable used the Dune release profile. Each workload ran in a fresh
process on CPU 2. The CPU used the `performance` governor.

The machine was an AMD Ryzen 9 9950X with 32 logical CPUs. CPU 18 was the
hardware-thread sibling of CPU 2. The operating system was NixOS with Linux
7.1.3.

Each process calibrated its operation count until one batch took at least
0.5 seconds or reached 16,777,216 operations. It then recorded nine samples.
One operation changed one source or keyed input and stabilized once.
Initial graph construction and workload construction were outside the timed
batch. The data-change and membership-change operations constructed the next
persistent map inside the timed batch.

For each implementation, the table shows the median of the three process
medians. The wall ratio is the median of the three paired Eta-to-reference
ratios. Allocation uses this per-operation formula:

```text
minor words + major words - promoted words
```

The raw measurements are:

- [process 1](raw/6f4c5cf7-run1.csv)
- [process 2](raw/6f4c5cf7-run2.csv)
- [process 3](raw/6f4c5cf7-run3.csv)

## Signal against Incremental

| Workload | Incremental | Eta Signal | Wall ratio | Incremental words | Eta words | Allocation ratio | Pairs at or below `1.20` |
|---|---:|---:|---:|---:|---:|---:|---:|
| changed, depth 1 | 53.9 ns | 492.5 ns | 8.98 | 6.0 | 328.0 | 54.67 | 0/3 |
| changed, depth 10 | 128.0 ns | 1.38 us | 10.78 | 6.0 | 472.0 | 78.67 | 0/3 |
| changed, depth 100 | 1.06 us | 15.29 us | 14.43 | 6.0 | 2,524.0 | 420.67 | 0/3 |
| cutoff, depth 10 | 32.4 ns | 1.20 us | 37.12 | 0.0 | 432.0 | not defined | 0/3 |
| dynamic switch | 145.0 ns | 4.07 us | 28.06 | 49.0 | 645.0 | 13.16 | 0/3 |

The static changed-path gap increases with graph depth. Eta also allocates more
per operation. The cutoff row allocates 432 words where Incremental allocates
none.

## Signal Map against Incr_map

| Workload | `Incr_map` | Eta Signal Map | Wall ratio | `Incr_map` words | Eta words | Allocation ratio | Pairs at or below `1.20` |
|---|---:|---:|---:|---:|---:|---:|---:|
| data change, 10,000 keys | 293.4 ns | 199.6 us | 683.68 | 186.0 | 740.0 | 3.98 | 0/3 |
| data change, 100,000 keys | 351.3 ns | 4.57 ms | 13,017.21 | 234.0 | 832.1 | 3.56 | 0/3 |
| membership change, 10,000 keys | 474.8 ns | 181.5 us | 386.14 | 349.5 | 995.0 | 2.85 | 0/3 |
| membership change, 100,000 keys | 577.6 ns | 4.77 ms | 8,031.43 | 439.5 | 1,128.1 | 2.57 | 0/3 |
| child change, 10,000 keys | 116.0 ns | 825.9 us | 7,118.99 | 84.0 | 434.0 | 5.17 | 0/3 |
| child change, 100,000 keys | 128.6 ns | 29.60 ms | 226,230.89 | 108.0 | 458.3 | 4.24 | 0/3 |

The map wall-time growth from 10,000 to 100,000 keys is much larger than the
reference growth:

| Change | `Incr_map` growth | Eta Signal Map growth |
|---|---:|---:|
| Data | 1.20 | 22.91 |
| Membership | 1.22 | 26.30 |
| Child | 1.11 | 35.84 |

The allocation growth is much smaller than the wall-time growth. The
measurements therefore show size-dependent public-path work. They do not
identify its cause.

## Change from the previous Eta version

The previous
[Eta and Jane Street comparison](../evidence/eta_incremental_performance/REPORT.md)
measured Eta commit `5614fa66`. The current run measured commit `6f4c5cf7`.
The measured historical commit is on a sibling Git history. Its `lib/eta`,
`lib/eio`, `lib/signal`, and `lib/signal_map` trees are identical to direct
ancestor `6b98144e`.

The nine comparable rows used the same machine, CPU, compiler, release profile,
reference commits, workload names, and 3-by-9 sample count. This section
recalculates both raw datasets with one aggregation method. It takes the median
of nine samples for each process. It then takes the median of the three process
medians.

| Workload | Previous Eta | Current Eta | Wall speedup | Previous words | Current words | Allocation reduction |
|---|---:|---:|---:|---:|---:|---:|
| changed, depth 1 | 10.98 us | 492.5 ns | 22.29 | 8,795 | 328.0 | 26.81 |
| changed, depth 10 | 14.68 us | 1.38 us | 10.64 | 12,287 | 472.0 | 26.03 |
| changed, depth 100 | 72.31 us | 15.29 us | 4.73 | 49,043 | 2,524.0 | 19.43 |
| cutoff, depth 10 | 11.64 us | 1.20 us | 9.68 | 9,780 | 432.0 | 22.64 |
| dynamic switch | 21.39 us | 4.07 us | 5.26 | 16,339 | 645.0 | 25.33 |
| data change, 10,000 keys | 13.81 ms | 199.6 us | 69.19 | 2,571,401 | 740.0 | 3,474.86 |
| data change, 100,000 keys | 307.77 ms | 4.57 ms | 67.31 | 25,106,642 | 832.1 | 30,173.42 |
| child change, 10,000 keys | 60.99 ms | 825.9 us | 73.84 | 6,993,791 | 434.0 | 16,114.36 |
| child change, 100,000 keys | 1.742 s | 29.60 ms | 58.83 | 72,998,406 | 458.3 | 159,276.49 |

The current scalar operations are `4.73` to `22.29` times faster. They allocate
`19.43` to `26.81` times fewer words.

The current map operations are `58.83` to `73.84` times faster. They allocate
`3,474.86` to `159,276.49` times fewer words.

The previous dataset has no membership-change rows. The current implementation
is much faster than the previous implementation, but it remains much slower
than Incremental and `Incr_map`.

This historical comparison is directional evidence and not a controlled A/B
comparison. It has these additional limits:

- Each historical process constructed all workloads before measurement. It
  retained all graphs and measured the workloads in sequence. The current
  harness starts a fresh process and constructs one graph for each workload.
  Thus, the resident graphs, heap shape, GC state, and shared engine state
  differed.
- The previous public interface was effectful. One long-lived
  `Eta.Runtime.run` executed each measured batch. The current public interface
  is synchronous. The reported improvement includes this protocol replacement.
- The previous Eta workload included one observer read inside each timed batch.
  The current Eta workload performs that read after timing. This difference
  favors the current implementation.

## Gate status

All 11 public matched rows failed the wall-time gate in all three process
pairs. The benchmark correctness checks passed.

This comparison covers complete public operations only. It does not run the
raw-kernel allocation gates or the Eta-only timer, observer, disposal, and
rollback rows.

This run has the observer-read deviation that the next section describes.
Thus, this run is diagnostic evidence and not a conforming acceptance run.
The deviation favors Eta and cannot change any row from failure to success.

## Measurement limits

- The benchmark ran on a shared workstation. CPU pinning reduced scheduler
  movement, but other processes were active.
- One `Incr_map` data-change process at 10,000 keys was slower than the other
  two. Its median was 435.1 ns instead of 291.9 or 293.4 ns. The median paired
  ratio and the gate result did not depend on this sample.
- The frozen harness uses `Unix.gettimeofday`.
- The frozen matrix requires the final observer read outside the timed batch.
  Incremental and `Incr_map` perform one final read inside each timed batch.
  Eta performs that read during the check after the batch. This protocol
  deviation makes the reference slower and favors Eta. The smallest paired
  ratio was `8.926`, so this deviation cannot change the gate conclusion.
- The Eta dynamic-switch measurements increased during every process. Run 1
  increased from 2.748 us to 6.187 us. Run 2 increased from 2.317 us to
  5.202 us. Run 3 increased from 2.307 us to 5.237 us. Thus, the reported
  `28.06` ratio is an order-dependent median and not a stable cost. The first
  sample from each process still exceeded its reference median by more than
  15 times.
- The map operations use different persistent-map implementations. Eta uses
  `Eta_signal_map.Map`. `Incr_map` uses `Core.Map`. This difference is part of
  the complete public-operation comparison.
- Adaptive calibration gives the faster reference more operations per sample.
  Every result is normalized per operation.
