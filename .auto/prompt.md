# Autoresearch: Eta Signal performance

## Objective

Reduce steady-state allocation and execution cost in `eta_signal` and
`eta_signal_map`. Compare the public Eta operations with Jane Street
Incremental and `Incr_map` under matched changed-value, cutoff, dynamic-bind,
retained-data, membership-churn, and child-only workloads.

The current primary workload changes the source of a scalar chain with 100
unary `map` nodes. It isolates the per-node execution cost that leaves Eta
thousands of times more allocation-heavy than Incremental.

## Metrics

- **Primary**: `signal_depth_100_words` (words/op, lower is better).
- **Secondary**: depth-100 wall time; scalar depth-one allocation and wall time;
  child-change allocation and wall time; membership-churn allocation and wall
  time.

Keyed child allocation fell from 1,419,614.50 to about 8,020 words per
operation and is now a regression guard. Scalar depth 100 still allocates about
19,682 words versus Incremental's six words, exposing approximately 122 words
per recomputed Eta node.

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

- Unary `Map` evaluation allocates generic `Static_eval` child, result, plan,
  dependency-list, and callback values for every recomputed node.
- `keyed_affected`, `keyed_plan_processed`, and pending-plan traversal may
  duplicate membership work.
- Incremental uses dense persistent graph state and specialized node kinds.
  Prefer similarly deep internal representations over public fast-path APIs.

## What's Been Tried

- No Signal optimization has been attempted in this session.
