# Autoresearch: Eta Signal performance

## Objective

Reduce the wall time of the five public `eta_signal` workloads in
`bench/signal_compare`. Jane Street Incremental is the fixed reference.

The workload set contains these operations:

- Changed propagation at depths 1, 10, and 100.
- Cutoff propagation at depth 10.
- Dynamic `bind` switching.

Each operation changes one source and stabilizes once. Graph construction and
the final observer read are outside the timed operation.

## Metrics

- **Primary**: `signal_wall_ratio_geomean` (unitless, lower is better).
  This value is the geometric mean of the five Eta wall times divided by the
  frozen Incremental medians from Eta commit `6f4c5cf7`.
- **Secondary**:
  - `signal_worst_wall_ratio`
  - Wall time and allocated words for each workload.
  - Depth growth from 1 to 10 and from 10 to 100.

## How to Run

Run:

```sh
./.auto/measure.sh
```

The script builds the release-profile harness. It runs each workload in a fresh
process on logical CPU 2. Each row has one sample after calibration and warm-up.
Set `SAMPLES=3` for a confirmation run.

`.auto/checks.sh` runs after each successful experiment. It builds all Signal
behavior, law, model, package, complexity, and install gates.

## Files in Scope

- `lib/signal/kernel/propagation.ml`
- `lib/signal/kernel/propagation.mli`
- `lib/signal/kernel/graph.ml`
- `lib/signal/kernel/graph.mli`
- `lib/signal/api/**`
- Focused tests under `test/signal/` and `test/laws/`
- `.auto/prompt.md` and `.auto/ideas.md`

## Off Limits

- Do not change `bench/signal_compare/**`.
- Do not change the reference medians, workload graph shapes, operations,
  calibration, timing boundaries, formulas, or correctness checks.
- Do not weaken public behavior, rollback, cutoff, observer, scope, timer,
  lifecycle, diagnostic, or affected-work rules.
- Do not add workload-specific branches, depth thresholds, hidden defaults,
  compatibility paths, feature flags, or new dependencies.
- Do not optimize Signal Map, Eta Crux, streams, or unrelated Eta packages for
  this metric.

## Constraints

- Target OxCaml `5.2.0+ox` only.
- Use `nix develop -c ...` for every build and correctness claim.
- Measure with `perf` or Memtrace before each non-obvious optimization.
- Use OxCaml local allocation, unboxed values, or zero-allocation checks when
  measurements identify a suitable hot allocation.
- Keep only primary metric improvements.
- Reject catastrophic regressions in any workload or allocation row.
- Preserve the synchronous owner-domain interface.
- Preserve `Propagation`, `Post_commit`, and `Graph` ownership.
- Add a focused regression test for each changed protocol.
- Changes to law-bearing `.mli` prose require a named executable law and a law
  registry row in the same experiment.
- Run the full Nix test and shipped-package gates before finalization.

## Initial Work

1. Measure the five-row baseline after the retained graph-wide scan fixes.
2. Profile the worst ratio and the allocation-heavy changed-depth row.
3. Inspect Incremental for the measured operation before changing Eta.
4. Prefer removal of generic pass work over workload-specific code.
