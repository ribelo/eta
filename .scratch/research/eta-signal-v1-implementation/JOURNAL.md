# Eta Signal V1 implementation journal

## 2026-08-04

### Baseline state

The implementation started at commit `6b98144e91e657594e72c6df1da270c62e18dc9d`.
The worktree was clean.
The branch was 115 commits ahead of `origin/master`.

The focused baseline gate passed:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

This gate ran the current Signal and Signal Map suites.
It included 83 core Signal tests, 48 contract tests, and the current model tests.

### Line counts

The production scope contains 21,678 lines in 57 files.
The full scoped OCaml source contains 50,388 lines in 126 files.

Eta Signal and Signal Map contain 15,396 production lines.
Incremental and Incr_map contain 13,534 production lines at the benchmark commits.

See `BASELINE.md` and `baseline/loc/*.tsv` for the method and file manifests.

### Benchmark

The quick smoke test and the full three-run comparison started on logical CPU 2.
The full comparison includes the 100,000-key workloads.

Raw results and the aggregate table will be added after all three runs finish.

### Probe and counter foundation

The first implementation slice added graph-branded private probe operations.
It also added the eight declared planning fault slots.

Each invariant owner now exposes its exact deterministic counter group.
The groups are disabled by default and become active after a probe reset.
This removes benchmark overhead when no economics measurement is active.

The focused counter gate passed:

```sh
nix develop -c dune build @signal-economics
```

The existing cleanup and timer owner tests also passed:

```sh
nix develop -c dune runtest test/signal/cleanup test/signal/timer --force
```

### Acceptance gates

The final result must satisfy all of these gates:

1. The production count is not more than 21,678 lines.
2. The full scoped count is not more than 50,388 lines.
3. Every Eta benchmark workload improves against the saved Eta baseline.
4. Every scalar workload is at most `1.20×` the matching Incremental workload.
5. Every keyed workload is at most `1.20×` the matching Incr_map workload.
6. The deterministic Signal economics gates pass.
7. The required OxCaml and mainline gates pass.

## 2026-08-04 - Baseline benchmark completed

- Ran the supplied full command three times with nine samples per point, pinned to CPU 2.
- The harness was placed inside a clean `git archive` of baseline commit `6b98144e91e657594e72c6df1da270c62e18dc9d`. This makes Dune link the exact repository sources instead of unrelated installed Eta artifacts.
- Raw source-linked runs are `baseline/benchmark/run1.csv`, `run2.csv`, and `run3.csv`.
- `baseline/benchmark/SUMMARY.md` reports the median of the three process-run means and the matching `1.20x` Jane Street ceilings.
- The full harness constructs every candidate before measurement. The current `Eta_signal.Default` candidates therefore share one graph containing the large keyed workloads. This exposes the forbidden graph-wide scans: even scalar updates take seconds in the full run, although an isolated depth-one smoke is about 10.6 microseconds.
- Final acceptance still requires both conditions for every row: improve over this source-linked Eta baseline and remain within the matching Jane Street ceiling. The final benchmark must use the accepted graph factory API; it must not restore a shared default graph to preserve these baseline numbers.

## 2026-08-04 - Slice 2: atomic transaction core

- Replaced monotonic integer transaction IDs with fresh physical identities.
- Replaced per-stage list allocations with a dense transaction cell array and typed staged-cell access. This follows Incremental's dense hot-state layout while preserving Eta rollback.
- Replaced the separate `Idle | Pure | Committed | Delivering` machine and mutable transaction-status fields with one `Idle | Planning | Delivering` phase owner.
- The atomic pass allocates its transaction and workspace before the one phase assignment. `Before_phase_install` therefore leaves exact `Idle` state and queued work.
- Added all eight required planning fault slots, sealed commit plans, total prepared-write interpretation, cleanup resource terminal states, and one-way node/scope lifetimes.
- Deleted `Eta_signal_stabilization`, `Eta_signal_stabilization_pass`, their copied harness paths, and their obsolete unit suites. Moved transaction, cleanup, scope, and node lifetime under the private engine library.
- Added `test/signal/atomic_pass/` with the N1 allocation boundary, all planning fault slots with retry, prepared-write-only commit, cleanup exactly-once transition, and one-way lifetime checks.
- Focused Signal and Signal Map suites pass after the replacement.
- Current production scope is 22,382 physical lines. This is 704 lines above the saved baseline because later engine-owner modules still coexist with the old scan scheduler. Slice 3 must delete those scans and recover the temporary delta; the final gate remains 21,678 lines.
