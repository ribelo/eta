# Node lifecycle probe

This directory contains throwaway research code.
It does not contain production Signal code.
Full ASD-STE100 compliance requires the official dictionary.

## Question

The rollback journal stores dense node slots.
A stale slot must not identify a replacement node.
The static path must allocate 4 words.
Commit must visit zero nodes.
Fixed-live churn must keep a bounded slot table.

## Candidates

Candidate A uses monotonic slots and tombstones.
It is safe because it never reuses a slot.
Its retained slot count is `initial live nodes + churn`.
The check prints this unbounded counterexample.

Candidate B uses a dense slot table, integer generations, and a free list.
Long-lived handles contain a slot and a generation.
Handle lookup compares both integers.
The allocator increments the generation before reuse.
It raises `Generation_overflow` before `max_int` can wrap.

Candidate B quarantines retired slots during an active pass.
Tentative creation can reuse a slot that was free before the pass.
A slot retired in the current pass stays quarantined until cleanup.
Commit resets the active value-journal length without visiting nodes.
Cleanup visits only the affected lifecycle nodes.
Rollback visits only the affected topology and values.
Rollback returns a failed tentative slot to the free list.

The arena has `Idle`, `Active`, and `Cleanup_pending` phases.
A commit with lifecycle actions enters `Cleanup_pending`.
Only cleanup can consume those actions and return the arena to `Idle`.
Pass start, quiescent allocation, and rollback reject `Cleanup_pending`.
Cleanup rejects `Idle` and `Active` without changing lifecycle records.

Commit performs three fixed scalar assignments.
The probe counts these assignments as commit steps.
The count is three for action lengths 0, 1, 4, and 1,000.
Commit contains no node loop, so its source-level node-visit count is zero.
Cleanup visits equal the action length.

Rollback uses three phases.
The first phase restores retired slots without removing tentative nodes.
The second phase requires and restores each active value-journal slot.
The third phase removes tentative nodes and clears pointer-bearing actions.
One action examination or journal resolution counts as one rollback visit.
Thus rollback visits equal `2 * action length + journal length`.

The active value journal stores slot integers only.
Each active integer identifies one incarnation for the complete pass.
The next pass overwrites the stale prefix before that prefix becomes active.
Successful and failed tentative churn retain at most `live nodes + 1` slots.
The checks use 1,024 and 100,000 churn operations.

`begin_pass` checks the pass identity before it changes the arena.
It raises `Pass_identity_exhausted` when the identity is `max_int`.
Production Signal must map this exception to its monotonic-counter graph error.
A pass at `max_int - 1` can commit or roll back to `max_int`.

Candidate C uses an epoch arena with compaction.
It bounds retained slots.
Compaction scans and repairs the complete live table.
The check prints this full-scan counterexample.

## Build and checks

Run this command from the repository root:

```sh
nix develop -c dune build \
  --root .scratch/research/eta-signal-execution-model/node-lifecycle-probe \
  --profile release probe.exe
```

Run all correctness and economics checks with one command:

```sh
nix develop -c \
  .scratch/research/eta-signal-execution-model/node-lifecycle-probe/_build/default/probe.exe \
  --check
```

## Measurements

The authoritative run uses CPU 2, nine samples, and three pairs.
Each workload runs in a fresh process.
Calibration starts with one operation and doubles the operation count.
Calibration stops at 0.5 seconds or 16,777,216 operations.

```sh
nix develop -c bash \
  .scratch/research/eta-signal-execution-model/node-lifecycle-probe/run.sh
```

The script writes `results.csv` and `summary.csv`.
Static candidate B rows immediately follow their matching Incremental rows.
Static setup and warm-up stay outside the measured operation.
Static passes branch around lifecycle cleanup when the action length is zero.
The checks require zero static cleanup calls and zero lifecycle entries.
Lifecycle rows use a fixed graph of eight live nodes.
The create row replaces one node with active-pass tentative creation.
The retire row cleans one retirement before quiescent reuse.
The reuse row starts with a committed free slot and cycles that slot.

Use these controls for a short run:

```sh
CPU=6 SAMPLES=3 PAIRS=1 nix develop -c bash \
  .scratch/research/eta-signal-execution-model/node-lifecycle-probe/run.sh
```

## Limits

The probe uses integer values and unary static propagation.
The lifecycle model omits dynamic edges and scopes.
The probe does not include Effect, Eio, observers, timers, or keyed nodes.
It does not prove boxed-value behavior or multi-domain behavior.
The weak-reference check depends on the OCaml garbage collector.
