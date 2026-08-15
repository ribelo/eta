---
kind: issue
status: ready-for-agent
requirements:
  - crxprf-1j2b
  - crxprf-d87c
  - crxprf-fnaf
  - crxprf-7hzp
  - crxprf-mgfx
  - crxprf-poom
  - crxprf-stwg
  - crxprf-rahl
  - crxprf-u62n
  - crxprf-6vth
  - crxprf-wdlj
  - crxprf-7av1
  - crxprf-s9le
  - crxprf-o8px
  - crxprf-zo9q
  - crxprf-wz1u
  - crxprf-ncyt
  - crxprf-x8nz
  - crxprf-5knl
  - crxprf-s5fr
  - crxprf-l8ty
  - crxprf-c3ay
  - crxprf-rwom
  - crxprf-nyax
  - crxprf-iva2
  - crxprf-3jp1
  - crxprf-4fm7
  - crxprf-xzr1
  - crxprf-x60a
---

# Projection performance gates

## Problem Statement

Typed projection delivery makes one promise that ordinary tests cannot check:
work and bytes are proportional to what changed, not to how much state is
active. One changed row among 100,000 must produce one update record, one encoded
entry, and the same byte count as one changed row among 10,000.

Semantic tests observe values, not cost. A correct implementation can still walk
the whole population per commit, encode the whole snapshot, or allocate a fresh
map per advance, and every semantic gate stays green.

A plain wall-clock benchmark does not close the gap either. It is
machine-dependent, so it cannot state a complexity claim, and a slow machine
turns a real bound into a flaky failure.

## Solution

Split the performance contract in two.

Semantic complexity bounds become a `PRF` law family with exact, machine
independent gates. Fixed benchmark workloads count deterministic events:
`batch_records`, `encoded_entries`, `encoded_bytes`, `cutoff_calls`,
`bootstrap_entries`, and a `key_compare_calls` ceiling. An exact-counter mismatch
fails the workload, so the bound is proved by counting, not by timing.

Benchmark budgets stay regression-only. The design names no absolute nanosecond
or word budget. The first full implementation run records the baselines in
`bench/results/`, and `bench/compare.exe --gate` polices later runs with the
existing regression rules, plus one zero-delta specification for the absent
capability and one cross-size allocation ratio.

## Requirements

In this section, "the system" is the Eta Crux benchmark suite: the
`bench_eta_crux.exe` executable of the `eta_crux` package, the `bench/compare.ml`
gate, and the recorded result files in `bench/results/`.

### Workloads

- The system shall provide the workloads `eta_crux.projection.no_change.10000` and `eta_crux.projection.no_change.100000`, in which one candidate recomputes and its cutoff suppresses it. ^crxprf-1j2b
- The system shall provide the workloads `eta_crux.projection.one_changed.10000` and `eta_crux.projection.one_changed.100000`, in which one candidate changes and passes its cutoff. ^crxprf-d87c
- The system shall provide the workloads `eta_crux.projection.attach.10000` and `eta_crux.projection.attach.100000`, in which one initial commit attaches every projection of the population. ^crxprf-fnaf
- The system shall provide the workloads `eta_crux.projection.bootstrap.10000` and `eta_crux.projection.bootstrap.100000`, in which one session replacement delivers a bootstrap of the whole population. ^crxprf-7hzp
- The system shall provide the workload `eta_crux.projection.absent`, in which a root with an empty catalog and no publication occurrence advances and delivers. ^crxprf-mgfx
- The system shall build one population per size and shall serve the no-change, one-changed, and attachment workloads of that size from it. ^crxprf-poom
- The system shall end each projection workload operation at the single delivery acknowledgment. ^crxprf-stwg

### Counters

- The system shall report the counters `batch_records`, `encoded_entries`, `encoded_bytes`, `cutoff_calls`, `key_compare_calls`, and `bootstrap_entries`, beside the existing `commits` and `deliveries` counters. ^crxprf-rahl
- The system shall report `commits = 1`, `deliveries = 1`, `batch_records = 0`, `encoded_entries = 0`, and `cutoff_calls = 1` for each no-change workload. ^crxprf-u62n
- The system shall report `batch_records = 1`, `encoded_entries = 1`, `cutoff_calls = 1`, and the `encoded_bytes` count that its test values fix, for each one-changed workload. ^crxprf-6vth
- The system shall report `batch_records = N` and `encoded_entries = N` for the attachment workload of population N. ^crxprf-wdlj
- The system shall report `deliveries = 1` and `bootstrap_entries = N` for the bootstrap workload of population N. ^crxprf-7av1
- The system shall report `commits = 1`, `deliveries = 1`, `batch_records = 0`, and `encoded_entries = 0` for the absent workload. ^crxprf-s9le
- The system shall keep `key_compare_calls` at or below eight times the population for each scaled workload. ^crxprf-o8px
- If an exact counter does not match or a ceiling counter is breached, then the system shall fail the workload with `failwith` and shall exit non-zero. ^crxprf-zo9q
- The system shall count encoded bytes at the format boundary. ^crxprf-wz1u

### Semantic complexity laws

- The system shall carry the registry rows PRF-01 to PRF-08 in `docs/design/eta-crux-v1/semantic-laws.md`, each with one claim, one named gate, one observation boundary, and one binding tag, and shall register `bench_eta_crux.exe` with `compare.exe --gate` as their executable suite. ^crxprf-ncyt
- The system shall prove that a commit with no changed value emits zero batch records and zero encoded entries, independent of the active population, and that cutoff work is proportional to recomputed candidates. ^crxprf-x8nz
- The system shall prove that preflight identity validation allocates zero words, through `[@zero_alloc]` on the preflight validation walk and on the pure projection helpers. ^crxprf-5knl
- The system shall prove that batch records and encoded entries are proportional to changed identities. ^crxprf-s5fr
- The system shall keep the per-operation median `allocated_words` of the one-changed workload at 100,000 at or below twice the median of the same workload at 10,000. ^crxprf-l8ty
- The system shall keep the `encoded_bytes` count of the one-changed workload exactly equal at 10,000 and at 100,000. ^crxprf-c3ay
- The system shall prove that a bootstrap is one delivery with one entry per active projection and one acknowledgment. ^crxprf-rwom
- The system shall keep the per-operation `allocated_words` median of the absent workload equal to the recorded pre-projection baseline median, with a wall-time median within 5 percent, in at least two of three run pairs. ^crxprf-nyax

### Comparison gate and baselines

- The system shall provide the `projection_absent_allocation` specification, the cross-size allocation ratio specification, and one `expected_crux_counters` entry for every exact counter, in `bench/compare.ml`. ^crxprf-iva2
- The system shall fail `bench/compare.exe --gate` on a zero-delta breach, a cross-size ratio breach, or a budget regression. ^crxprf-3jp1
- The system shall report a budget regression when a median wall time grows by more than 15 percent, or when median allocated words grow by more than 5 percent and by more than one word, in at least two of three run pairs. ^crxprf-4fm7
- When the first full implementation run finishes, the repository shall contain its recorded result file in `bench/results/` as the budget baseline of every new row. ^crxprf-xzr1
- The system shall keep the projection performance gates out of `dune runtest`. ^crxprf-x60a

## Implementation Decisions

Provenance: [Performance and zero-cost
gates](../../wayfinder/eta-crux-typed-projection-delivery/issues/13-performance-and-zero-cost-gates.md)
and change 3 of the [implementation
plan](../../wayfinder/eta-crux-typed-projection-delivery/issues/15-implementation-plan.md).

**Two gate classes, deliberately separated.** Semantic complexity bounds are
laws with exact machine-independent gates. Benchmark budgets are not laws; the
design names no absolute threshold and relies on recorded baselines with the
existing regression rules.

**Modules.** `lib/crux/bench/bench_eta_crux.ml` for the workloads and counters,
`bench/compare.ml` for the new specifications, `lib/crux/crux_projection.ml` for
the `[@zero_alloc]` sites, and `docs/design/eta-crux-v1/semantic-laws.md` for the
PRF rows. `bench/run.sh` is unchanged.

**Counter mechanism.** The existing workload counter pattern (`commits`,
`deliveries`, `child_visits`) carries the new counts. Encoded bytes use the
existing `Counting_format` pattern at the format boundary. GC counters
(`allocated_words`, `minor_words`, `promoted_words`, `major_words`) come from the
existing harness.

**Exact versus ceiling.** `batch_records`, `encoded_entries`, `encoded_bytes`,
`cutoff_calls`, `bootstrap_entries`, `commits`, and `deliveries` are exact and
hard-fail on any mismatch. `key_compare_calls` is a ceiling, because the internal
comparator call count is an implementation detail while its order of growth is
not.

**Baselines.** PRF-08 compares against the pre-projection full-suite result that
task T0 recorded in [Fallible codec](01-fallible-codec.md). Every other row takes
its budget baseline from the first full run of the implemented capability.

**Binding tags.** PRF-06 and PRF-07 are `serialized-only`. Every other PRF row
runs on the identity binding and is `identity-only`.

**Single profile.** Only the changed complete-value batch push profile has byte
workloads. The snapshot-push and pull byte clauses of PRF-06 do not exist.

## Testing Decisions

The benchmark executable is itself the gate. A good workload observes counted
events at a stated boundary and fails loudly on a mismatch; it asserts nothing
about internal data structures.

**Seams.**

1. The public `Eta_crux` root and driver surface, driven by the benchmark
   harness, with the workload counters as the observation.
2. The wire format boundary, through the existing counting format, for
   `encoded_bytes`.
3. The compiler, through `[@zero_alloc]`, for the allocation-free preflight walk
   and pure helpers.
4. `bench/compare.exe --gate` over recorded result files, for zero-delta,
   cross-size ratio, and regression checks.

**Named gates.** `bench_projection_no_change`, `bench_projection_one_changed`,
`bench_projection_attach`, `bench_projection_bootstrap`, and the `compare.exe`
specifications `projection_absent_allocation` and the cross-size ratio.

**Failure criteria.** An exact-counter mismatch or ceiling breach fails the
workload with `failwith` and the executable exits non-zero. A `[@zero_alloc]`
violation fails compilation. A zero-delta, ratio, or regression breach fails
`bench/compare.exe --gate`.

**Prior art.** The existing `eta_crux.` workloads and counters in
`lib/crux/bench/bench_eta_crux.ml`, the `Counting_format` byte counter, the
`compare.ml` regression rules, and the existing disabled-path allocation specs
`structural_reset_disabled_allocation`, `poll_disabled_allocation`, and
`post_commit_effect_observer_disabled_allocation`.

**Commands.** `nix develop -c dune build @bench` to compile,
`nix develop -c bash bench/run.sh --quick` for a fast snapshot, and
`nix develop -c bash bench/run.sh` for the recorded run. `dune runtest` does not
run these gates.

## Out of Scope

- Absolute nanosecond or word budgets in the design.
- Performance gates inside `dune runtest`.
- Byte workloads for the deleted snapshot-push and pull profiles.
- Cross-machine performance comparison. Baselines are local records.
- Optimization work beyond what the stated bounds require.

## Further Notes

This spec lands after [Typed projection
delivery](02-typed-projection-delivery.md). Change 2 keeps
`bench_eta_crux.ml` compiling with a minimal migration; the new workloads arrive
here.

The cross-size ratio of two is deliberate slack. A logarithmic path grows by
about 1.25 times between 10,000 and 100,000, so the bound admits the persistent
structure and excludes linear behavior.
