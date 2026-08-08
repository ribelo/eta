# Autoresearch: Eta Signal Map performance

## Objective

Reduce the steady-state wall time of the six public `eta_signal_map` workloads
in `bench/signal_compare`. Jane Street `Incr_map.mapi'` is the fixed reference.

The workloads cover one retained data change, one membership change, and one
child-source change at 10,000 and 100,000 keys. Each operation performs one
change and one stabilization. Initial graph construction and the final observer
read are outside the timed Eta operation.

The implementation must keep the current behavior contract, affected-work
bounds, rollback rules, stable child identity, and synchronous owner-domain
interface.

## Metrics

- **Primary**: `map_wall_ratio_geomean` (unitless, lower is better). This is the
  geometric mean of the six Eta wall times divided by the fixed `Incr_map`
  medians from the clean `6f4c5cf7` comparison.
- **Secondary**:
  - `map_worst_wall_ratio`
  - wall time and allocated words for every data, membership, and child row
  - 100,000-key to 10,000-key wall-time growth for each change class

The first complete comparison gives a primary ratio near `5,982` with this
aggregation. The worst row is child change at 100,000 keys, near `230,100`
times the reference.

## How to Run

Run:

```sh
./.auto/measure.sh
```

The script builds the frozen release-profile harness. It runs each Eta workload
in a fresh process on logical CPU 2. Each row uses one measured sample after the
harness calibration and warm-up. Set `SAMPLES=3` for a confirmation run.

`.auto/checks.sh` runs automatically after each successful experiment. It runs
the Signal behavior, law, model, package, and complexity gates.

## Files in Scope

- `lib/signal_map/kernel/eta_signal_map_kernel.ml`
  - persistent map operations and symmetric diff
- `lib/signal_map/api/eta_signal_map_api.ml`
  - the public map adapter and `Package_graph` plan
- `lib/signal/kernel/propagation.ml`
  - stable-family reconciliation, propagation queues, rollback, and graph
    storage
- `lib/signal/kernel/propagation.mli`
  - private propagation seam for an implementation that needs a deeper
    operation
- `lib/signal/kernel/graph.ml`
  - owner-domain execution and the sealed stable-family protocol
- `lib/signal/kernel/graph.mli`
  - private graph seam for a required protocol change
- Focused tests under `test/signal/`, `test/signal_map/`, and `test/laws/`
- `.auto/prompt.md` and `.auto/ideas.md` for durable experiment knowledge

## Off Limits

- Do not change `bench/signal_compare/**`.
- Do not change reference medians, workload sizes, operations, calibration,
  timing boundaries, formulas, or correctness checks.
- Do not weaken public behavior, rollback, cutoff, observer, scope, timer,
  lifecycle, diagnostic, or affected-work rules.
- Do not add benchmark-specific branches, size thresholds, hidden defaults,
  compatibility paths, feature flags, or new dependencies.
- Do not make the root `eta` package depend on Signal or Signal Map.
- Do not optimize Eta Crux, streams, timers, or unrelated Eta packages.

## Constraints

- Target OxCaml `5.2.0+ox` only.
- Use `nix develop -c ...` for every build and correctness claim.
- Keep only primary metric improvements. Reject worse or unchanged results.
- Treat allocation and every individual row as tradeoff monitors. Reject a
  catastrophic secondary regression despite a primary improvement.
- Preserve the public synchronous owner-domain interface.
- Preserve `Propagation`, `Post_commit`, and `Graph` ownership.
- Preserve the sealed `Package_graph` boundary. `eta_signal_map` must not depend
  on the private Signal kernel.
- Add a focused regression test for each changed protocol.
- Changes to law-bearing `.mli` prose require the named executable law and law
  registry update in the same experiment.
- Run the full Nix test and shipped-package gates before finalization.

## Current Diagnosis

The persistent map already patches one key with logarithmic comparisons. The
deterministic gates report one selected child for a child-only change. Allocation
is hundreds of words, not proportional to the key count. The dominant wall cost
is therefore in the graph driver.

A release-profile `perf` capture of child change at 100,000 keys found:

- about 40% in `Propagation.enqueue_stale_freshness`
- about 15% in `Propagation.clear_queues`
- about 10% in major-GC marking
- the remaining large samples in equality and hash operations called by the
  stale-freshness scan

`enqueue_stale_freshness` scans every graph slot to find nodes with duplicate
dependencies. The 100,000-key graph has hundreds of thousands of nodes, although
the measured change affects one child. `clear_queues` also scans every slot after
the queue drain.

## First Experiments

1. Replace the duplicate-dependency full scan with a generation-safe registry
   of candidate nodes. Include dynamic bind nodes whose dependencies can change.
   Preserve the duplicate-dependency freshness regression.
2. Remove the successful-pass `clear_queues` full scan, or replace it with
   affected-node cleanup. Queue pop already clears the popped node fields.
   Preserve rollback queue cleanup.
3. Reprofile all three 100,000-key rows after both full scans are gone.

## Inherited Research

The prior Signal autoresearch session showed that graph-wide scans, timer
planning, observer ordering, and generic stabilization machinery dominated
keyed work. Its code belongs to the old execution engine and must not return as
a compatibility path.

The `.auto/` directory in `/home/ribelo/projects/ribelo/ocaml/Eta` currently
contains H2-over-TLS research. It has no Signal Map findings.

## What's Been Tried

- The new Signal Map optimization segment has no experiments yet.
- The current execution-model redesign reduced map time by about 59 to 74 times
  and allocation by thousands of times against the old public implementation.
  It still retained graph-wide stabilization scans.
