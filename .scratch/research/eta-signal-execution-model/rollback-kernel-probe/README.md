# Rollback kernel prototype

This directory contains throwaway research code.
It does not contain production Signal code.
Full ASD-STE100 compliance requires the official dictionary.

The probe compares two rollback models.
Each model has a functor kernel and a monomorphic kernel.
The kernel uses retained values, pass stamps, height buckets, and direct unary propagation.

## Candidates

R1b and R1m use sparse undo with O(1) commit.
The first write saves the published value in `prev`.
Rollback restores the touched nodes in reverse order.
Commit resets the active buffer length in O(1) time.

R2 and R2m use prepared publication.
Recomputation writes a candidate value.
Reads use the candidate value for the current pass.
Commit publishes all touched candidates.
Rollback resets the buffer length in O(1) time.
It does not clear the old slots on the failure path.
Thus R2 can retain node pointers until later passes overwrite the slots.

R1m and R2m keep their rollback fields in each node.
They do not use a functor or a separate rollback-state record.

R1n is a timing control.
It keeps the R1m fields and admission retention.
It does not record touched nodes.
It does not restore failed writes.
Therefore, R1n is not a correct rollback kernel.

R1a is a timing control for the parent-loop shape.
It uses `Array.iter` where R1m uses an explicit `for` loop.

R1i is the index-journal candidate.
Each node has one dense integer index.
The touched journal and admission buffer contain integers.
Rollback resolves each integer through the dense node table.
The success path does not store node pointers in journal arrays.
The node table adds one retained pointer for each graph node.
Dynamic topology must define index reuse or tombstone cleanup.

The touched buffers use an `Obj.t array`.
The graph allocates this buffer once and reuses it.
An O(1) commit leaves stale pointers in the used prefix.
A later pass overwrites this prefix from slot zero.
A stale pointer remains until a later pass overwrites its slot.
The stale prefix is not longer than the largest touched count.
For a static graph, the graph already references these nodes.
Dynamic-topology retention belongs to the next prototype.

The R1 control walks the journal and clears each slot on commit.
The R1w control walks the journal without clearing each slot.
These controls measure the cost of the walk and slot clearing.
The `--check` command also measures slot-clearing allocation.

R3 uses a lazy epoch.
The executable prints a counterexample for this candidate.
An O(1) rollback leaves a failed value in a node.
A later cutoff can prevent the retry from writing that node.
A later commit then exposes the failed value.
Repair requires a walk of the touched nodes.

## Execution seam

All four candidate kernels expose the same execution seam.

```ocaml
val set : graph -> var -> int -> unit
val stabilize : graph -> (stabilization, error) result
val value : signal -> int
val var_value : var -> int
```

The error type is:

```ocaml
type error =
  | Defect of exn
  | Reentrant_stabilization
```

## Build

Run this command from the repository root:

```sh
nix develop -c dune build \
  --root .scratch/research/eta-signal-execution-model/rollback-kernel-probe \
  --profile release probe.exe
```

## Correctness checks

Run this command from the repository root:

```sh
nix develop -c \
  .scratch/research/eta-signal-execution-model/rollback-kernel-probe/_build/default/probe.exe \
  --check
```

Each failed check prints its expected and observed values.
The checks cover the inherited static-kernel gates.
They also cover failure, retry, cutoff baseline, demand, frontier repair, and reentry.

## Measurements

The authoritative run uses CPU 2, nine samples, and three pairs.

```sh
nix develop -c bash \
  .scratch/research/eta-signal-execution-model/rollback-kernel-probe/run.sh
```

The script writes `results.csv` and `summary.csv` in this directory.
The script starts each workload in a fresh process.
It runs each Incremental workload immediately before its matching candidate.

Use this command for a short provisional run:

```sh
CPU=6 SAMPLES=3 PAIRS=1 nix develop -c bash \
  .scratch/research/eta-signal-execution-model/rollback-kernel-probe/run.sh
```

## Limits

The probe uses integer values.
The graph topology is static.
The probe does not include Eta Effect or Eio.
The probe does not cover observers, timers, dynamic scopes, keyed nodes, or post-publication failures.
The probe does not prove behavior for boxed values.
The probe does not prove multi-domain behavior.
The use of `Obj.t` is prototype code.
R1n is only a timing control and fails the rollback contract by design.
