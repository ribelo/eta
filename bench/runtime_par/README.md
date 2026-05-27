# bench/runtime_par — Par benchmark suite

Eight kernels covering the workload taxonomy work-stealing schedulers
care about. Used both for human-readable health checks and as the
numeric target for autoresearch loops over `lib/par/src/`.

## Kernels

| File                         | Workload                                  | What it stresses                              |
|------------------------------|-------------------------------------------|-----------------------------------------------|
| `kernel_fib.ml`              | fib(n) via `join`, cutoff=20              | Balanced binary recursion tree                |
| `kernel_qsort.ml`            | `par_sort` over 1M random ints            | Recursive partition, irregular subproblems    |
| `kernel_map.ml`              | `par_map` over 4M ints, 32 mix rounds     | Regular array work, indirect-call overhead    |
| `kernel_reduce.ml`           | `par_reduce` (max) over 8M ints           | Tree reduction, `combine` overhead            |
| `kernel_pathological.ml`     | Skewed binary tree (right children leaf)  | Work-stealing on hard imbalance               |
| `kernel_irregular.ml`        | `par_for` with sin-modulated cost         | Dynamic load balancing of varying chunks      |
| `kernel_matmul.ml`           | Dense N×N float matmul, `par_for ~chunk:1`| Compute-bound, cache friendly per-row task    |
| `kernel_micro_join.ml`       | Tons of shallow `join` on tiny work       | Scheduler overhead per join — stress test     |

`micro_join` is intentionally allowed to slow down: it measures what
happens when an algorithm decomposes too far. A scheduler regression
that affects per-join cost shows up here first.

## Boundary: scheduler vs benchmark

The benchmarks live outside `lib/par/` on purpose. The dune
file declares one library dependency:

```
(libraries eta_par unix)
```

That is all every kernel can see: the public surface of `Par` plus
`Unix` for clocks. The internal `Scheduler` module is `private_modules`
in `lib/par/src/dune`, and there is no escape hatch.

Implications:

- **Adding a benchmark cannot reach into the scheduler.** The build
  fails if you try, with a clear "Library not found" message.
- **Improving a benchmark number requires improving the public API or
  the scheduler itself.** Both are visible in any diff.
- **`Obj.magic` in a kernel file is a red flag.** None of the existing
  kernels use it; reviewers should reject any introduction of it
  without an extremely good reason.

In short: gaming the bench means changing public files, which means
the diff makes the gaming obvious. There is no per-bench shortcut.

## Running

```bash
# Full suite, 5 iterations, 4 workers (~6s):
nix develop -c dune exec bench/runtime_par/runtime_par.exe

# Quick mode for autoresearch iteration (~1.5s):
nix develop -c dune exec bench/runtime_par/runtime_par.exe -- --quick

# One kernel only (still validates against serial):
nix develop -c dune exec bench/runtime_par/runtime_par.exe -- --kernel fib

# Different worker counts:
nix develop -c dune exec bench/runtime_par/runtime_par.exe -- --workers 8

# Via the @bench alias (always quick mode):
nix develop -c dune build @bench
```

## METRIC output

For autoresearch parsing the suite emits `METRIC name=value` lines:

- Per kernel:
  - `TIME_<KERNEL>_MS` — median wall-clock of the parallel run (ms)
  - `SPEEDUP_<KERNEL>` — `serial_ms / parallel_ms` (>1 is good)
  - `MINOR_<KERNEL>` — minor heap words allocated, summed across
    all worker domains (Gc.stat)
- Aggregate:
  - `TOTAL_PARALLEL_MS` — sum of per-kernel medians (lower better)
  - `TOTAL_MINOR_WORDS` — sum of per-kernel allocations
  - `GEOMEAN_SPEEDUP` — geometric mean of per-kernel speedups
    (higher better; pulled down by `micro_join`)

`TOTAL_PARALLEL_MS` is the recommended primary metric: it's
lower-better, it's a pure wall-clock number (no interpretation needed),
and it's a sum so individual kernels show up proportionally to their
weight. To target a single workload, optimise the matching
`TIME_<KERNEL>_MS`.

## Validation

Every parallel run is checksum-checked against the serial baseline.
Mismatch prints `! kernel: parallel checksum X != serial Y` and the
suite reports `FAIL` at the end. Float kernels (`pathological`,
`matmul`) round their checksum to an integer to avoid summation-order
sensitivity.

## Adding a kernel

1. Drop `kernel_<name>.ml` in this directory. It must implement:
   ```
   val name : string
   val description : string
   val run_serial : quick:bool -> unit -> string
   val run_parallel : quick:bool -> Par.Pool.t -> string
   ```
   Both run functions return the same checksum on the same input.
2. Add `(module Kernel_<name>)` to the `kernels` list in
   `runtime_par.ml`.
3. Make sure the workload sizes hit ~50ms parallel in default mode and
   ~10ms in `--quick` so signal/noise is acceptable.
