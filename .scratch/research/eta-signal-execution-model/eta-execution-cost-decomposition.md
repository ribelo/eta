# Eta execution-cost decomposition

Date: 2026-08-05

## Scope

This report answers the
[Eta execution-cost decomposition](../../../docs/wayfinder/eta-signal-execution-model/issues/03-eta-cost-decomposition.md)
ticket.

The report measures the current scalar changed-value path. It does not propose
the replacement kernel.

The probe uses commit `af5233081911a917b42c7a2deba2e5927ae8efcb`.
The toolchain is OxCaml `5.2.0+ox` with Dune `3.22.2`.

## Result

The current raw planning path allocates `729 + (68 * depth)` words per
operation. It allocates 797 words at depth 1.

The complete public path with Eio and one no-op observer allocates
`5,305 + (68 * depth)` words. The fixed difference is 4,576 words.

The fixed allocation difference has these measured parts:

1. Eta Effect adds 10 words.
2. One fused graph-lane acquisition adds 169 words.
3. The split public protocol adds 1,083 words.
4. The Eio runtime adapter adds 1,174 words.
5. Observer demand and delivery add 2,140 words.

An active, non-firing timer adds `2,315 + (6 * depth)` words. Timer presence
also activates a triangular dirty-journal search on the changed chain.

The ordinary public path does not yield or wait. Thus its Eio difference is
runtime-adapter cost, not scheduler-switch cost.

One explicit Eio-backed `Effect.yield` adds 53 words. This diagnostic control
keeps the graph operation unchanged.

## Matched operation

The graph contains one watched integer variable and `depth` unary maps. Each map
adds one to its input.

One operation does this work:

1. Increment the source integer.
2. Set the source.
3. Stabilize once.
4. Check the final output after the batch.

The probe uses depths 1, 10, and 100. These depths match the frozen comparison
workloads.

The observer-free rows retain one private demand reference. The observer rows
use the public observer as the demand owner.

The timer row adds one public one-hour timer and one timer observer. The timer
does not fire during measurement.

## Layer definitions

The probe has two related ladders.

### Private planning ladder

| Layer | Operation boundary |
|---|---|
| `raw` | `Var.set_unlocked`, `begin_stabilize`, and direct planning completion under one batch-held lane |
| `effect` | The same raw operation in one prebuilt Eta Effect step |
| `lane` | The same fused raw operation with one uncontended lane acquisition per operation |

The batch-held lane removes per-operation Effect and lane edges from `raw`.
Its fixed batch cost becomes a small fractional allocation.

### Public operation ladder

| Layer | Operation boundary |
|---|---|
| `public_sync` | Public `Var.set` and `stabilize` on a synchronous runtime |
| `public_eio` | The same operation on the Eio runtime |
| `observer_eio` | `public_eio` with public demand and no-op observer delivery |
| `timer_eio` | `observer_eio` with one demanded, non-firing timer |

`lane` to `public_sync` is not a pure adapter difference. It also adds separate
source admission, stabilization, cleanup, and completion protocols.

`scheduled_eio` branches from `public_eio`. It adds one `Effect.yield` before
each public graph operation.

## Measurements

The full command was:

```sh
SAMPLES=9 nix develop -c bash \
  .scratch/research/eta-signal-execution-model/cost-probe/run.sh \
  > .scratch/research/eta-signal-execution-model/cost-probe/results.csv
```

Each layer ran in a fresh process pinned to CPU 2. The host has an AMD Ryzen 9
9950X processor.

The harness calibrates each batch to 0.5 seconds. It uses the frozen benchmark
allocation and wall-time formulas.

The table contains median nanoseconds and allocation words per operation:

| Depth | Raw | Public sync | Public Eio | Observer Eio | Timer Eio |
|---:|---:|---:|---:|---:|---:|
| 1 | 563 ns / 797 | 1,643 ns / 2,059 | 3,757 ns / 3,233 | 6,253 ns / 5,373 | 9,303 ns / 7,694 |
| 10 | 1,378 ns / 1,409 | 2,422 ns / 2,671 | 4,567 ns / 3,845 | 6,999 ns / 5,985 | 10,305 ns / 8,360 |
| 100 | 9,478 ns / 7,529 | 10,553 ns / 8,791 | 12,657 ns / 9,965 | 15,134 ns / 12,105 | 24,148 ns / 15,020 |

The measured layer differences are:

| Layer difference | Words | Depth 1 | Depth 10 | Depth 100 |
|---|---:|---:|---:|---:|
| Raw planning | `729 + 68d` | 563 ns | 1,378 ns | 9,478 ns |
| Effect minus raw | 10 | 15 ns | -3 ns | 81 ns |
| Lane minus Effect | 169 | 264 ns | 265 ns | 210 ns |
| Public sync minus lane | 1,083 | 801 ns | 781 ns | 784 ns |
| Public Eio minus public sync | 1,174 | 2,114 ns | 2,145 ns | 2,104 ns |
| One yield minus public Eio | 53 | 137 ns | 177 ns | 41 ns |
| Observer minus public Eio | 2,140 | 2,496 ns | 2,432 ns | 2,477 ns |
| Timer minus observer | `2,315 + 6d` | 3,050 ns | 3,306 ns | 9,014 ns |

The Effect wall-time difference is below this method's resolution. Cross-process
wall differences are diagnostic estimates, not acceptance gates.

Allocation was stable across all nine samples. Small fractional values are
fixed measurement costs divided by the operation count.

The complete observer allocation matches the frozen public benchmark exactly at
all three depths. The cross-check values are 5,373, 5,985, and 12,105 words.

The raw samples are in
[`cost-probe/results.csv`](cost-probe/results.csv). The medians and declared
baselines are in [`cost-probe/summary.csv`](cost-probe/summary.csv).

## Source attribution

The raw row calls the synchronous planning entry at
`lib/signal/kernel/eta_signal_kernel.ml:5504-5570`. It finishes the planning
phase directly at lines 2073-2076.

This path still includes the current scheduler, staged cells, transaction,
commit plan, and rollback preparation. It excludes per-operation Effect, lane,
observer, timer, and public completion work.

The raw allocation slope is exactly 68 words for each added unary map. Source
inspection does not assign every word to one allocation site.

The Effect row uses the prebuilt loop shape from the frozen benchmark. The lane
row adds `Eta_signal_lane.with_sync` once per fused operation.

The public synchronous row restores separate `Var.set` and `stabilize` calls.
It also restores their cleanup and delivery-completion shells.

The Eio row changes only the runtime adapter. The matched operation creates no
Eio child, promise wait, timer wake, or explicit yield.

The observer row adds event collection and no-op callback delivery. It includes
the observer protocol's additional lane sections.

## Timer contamination

Timer presence creates an active refresh context for each non-quiescent
stabilization (`eta_signal_kernel.ml:5611-5623`).

Each changed signal marks its dependent parents through
`notify_signal_changed` (`eta_signal_kernel.ml:4576-4584`).

An active refresh records each parent's prior dirty state
(`eta_signal_kernel.ml:3375-3382`). The record uses
`mark_dirty_recording_previous`.

That function uses `List.exists` before each insertion
(`eta_signal_kernel.ml:1215-1221`). The list grows once for each changed parent.

Thus a depth-`d` chain performs a triangular number of identity checks. The same
path allocates exactly six extra words for each map.

The depth-100 timer difference rises to 9,014 ns. This result is consistent with
the source-level triangular search.

## Design consequences

The current raw planner is not an eligible replacement kernel. Its depth-1
allocation is 797 words, which exceeds the 100-word gate.

Adapter optimization alone cannot satisfy the gate. Removing all fixed adapters
still leaves `729 + (68 * depth)` words.

Eta Effect is not the main allocation source. Its matched raw wrapper adds only
10 words per operation.

The uncontended fused lane adds 169 words. Lane contention, parking, and
cancellation are separate workload classes.

The public protocol adds a fixed 1,083 words before Eio. A replacement seam must
avoid rebuilding this protocol for raw static passes.

The Eio adapter adds 1,174 words without scheduler switching. Candidate reports
must not label this complete difference as Eio scheduling.

Observer delivery adds 2,140 fixed words. Candidate kernels must measure
delivery separately from propagation.

Timer machinery affects unrelated scalar propagation. A selected kernel must
confine timer rollback state to timer-affected work.

## Deferred measurements

Issue 10 owns timer activation, wake, firing, cancellation, and disposal costs.
The non-firing timer row does not measure those edges.

Issue 10 also owns observer failure and retry costs. This report measures only a
successful no-op callback.

Lane contention needs a separate queued-fiber workload. The current lane row is
uncontended.

Issue 04 must define stable wall-time gates. This report supplies diagnostic
medians and exact allocation baselines.

## Decision

Use the two ladders for all later prototypes. Report raw planning before Effect,
lane, runtime, observer, or timer adapters.

Reject any static candidate whose raw path exceeds 100 words or scales with
graph depth after warm-up.
