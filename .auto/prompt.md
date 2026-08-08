# Autoresearch: Eta Signal dynamic-switch wall time

## Objective

Reduce the wall time of dynamic `bind` switching in `bench/signal_compare`.
Jane Street Incremental is the fixed reference (145.03 ns frozen median).

The workload set contains these operations:

- Changed propagation at depths 1, 10, and 100.
- Cutoff propagation at depth 10.
- Dynamic `bind` switching.

Each operation changes one source and stabilizes once. Graph construction and
the final observer read are outside the timed operation.

## Metrics

- **Primary**: `signal_dynamic_wall_ns` (nanoseconds, lower is better).
- **Secondary**:
  - `signal_dynamic_words`
  - `signal_changed_100_words`
  - `signal_wall_ratio_geomean`
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
- Keep only primary allocation improvements.
- Reject catastrophic wall-time regressions or allocation regressions in another
  workload.
- Preserve the synchronous owner-domain interface.
- Preserve `Propagation`, `Post_commit`, and `Graph` ownership.
- Add a focused regression test for each changed protocol.
- Changes to law-bearing `.mli` prose require a named executable law and a law
  registry row in the same experiment.
- Run the full Nix test and shipped-package gates before finalization.

## Initial Work

1. Measure the retained dynamic-switch wall baseline.
2. Profile the dynamic row with release symbols and `perf`.
3. Inspect the matching Incremental bind path after the profile identifies
   Eta's dominant cost.
4. Prefer removal of generic pass work over workload-specific code.
