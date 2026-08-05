# Autoresearch: Eta Signal performance

## Objective

Reduce steady-state allocation and execution cost in `eta_signal` and
`eta_signal_map`. Compare the public Eta operations with Jane Street
Incremental and `Incr_map` under matched changed-value, cutoff, dynamic-bind,
retained-data, membership-churn, and child-only workloads.

The current primary workload changes one stable child in a keyed map with
10,000 entries. It is the largest known steady-state cost center that does not
change input-map topology.

## Metrics

- **Primary**: `signal_map_child_10k_wall_ns` (ns/op, lower is better).
- **Secondary**: child-change allocation; scalar depth-one allocation and wall
  time; membership-churn allocation and wall time.

Allocation was the first primary metric. It fell from 1,419,614.50 to 8,333.08
words per operation and is now a regression guard. The current target is the
median of three in-process wall-time samples.

## How to Run

`./.auto/measure.sh`

The script builds the frozen comparison harness in release mode. Every
workload runs in a fresh process pinned to one logical CPU.

## Files in Scope

- `lib/signal/kernel/eta_signal_kernel.ml`: graph ownership and public runtime
  integration.
- `lib/signal/engine/**`: stabilization, transactions, observers, graph
  scheduling, timers, and internal data structures.
- `lib/signal_map/**`: persistent map and keyed reconciliation.
- Public `.mli` and API files only when an optimization requires an honest
  representation or contract change.
- Focused tests for every changed protocol.

## Off Limits

- `bench/signal_compare/**` after the baseline commit.
- Existing benchmark inputs, operation counts, checks, and metric formulas.
- Weakening tests, diagnostics, lifecycle fences, rollback, observer ordering,
  cutoffs, or keyed child identity.
- New dependencies, compatibility shims, and benchmark-specific branches.

## Constraints

- Preserve all Signal V1 semantics and executable laws.
- Target OxCaml `5.2.0+ox` only. OxCaml modes, stack allocation, unboxed
  layouts, and zero-allocation checks are available for production changes.
- Use Nix/OxCaml for every build and test claim.
- Keep the branch linear over `master`.
- An optimization must explain a general source-level cost. Do not fit map
  size, key value, chain depth, callback identity, or benchmark names.
- Keep only primary allocation improvements. Reject allocation-neutral
  complexity unless it removes code or produces a large verified time win.
- Never optimize away required callback delivery. Both comparison sides
  install a no-op observer callback.

## Benchmark Audit

The inherited harness covered changed scalar chains, cutoff, dynamic bind,
retained keyed data, and child-only keyed changes. Three defects were fixed
before freezing:

- A default full run constructed unrelated Eta candidates in one global graph.
  The harness now requires one `--only` workload per fresh process.
- Incremental observers had no update callback while Eta observers delivered
  one. Both sides now install a no-op callback.
- Keyed insertion and removal were absent. Membership-churn workloads at
  10,000 and 100,000 entries now alternate one insertion and one removal.

## Starting Hypotheses

- Child-only reconciliation allocates transaction plans, ordered-map patches,
  observer delivery state, and generic graph scheduling structures for one
  affected child.
- `keyed_affected`, `keyed_plan_processed`, and pending-plan traversal may
  duplicate membership work.
- Incremental uses dense persistent graph state and specialized node kinds.
  Prefer similarly deep internal representations over public fast-path APIs.

## What's Been Tried

- No Signal optimization has been attempted in this session.
