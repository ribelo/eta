# DX-E29 Journal — follow-up 1 (review verdict + mechanical fixes)

The sealed `journal.md` is untouched; follow-ups live here per protocol.

## Verdict

The PR-style review returned **promote**: the design stands, the kill case
(T4 + `sync_option`, in-repo frequency ≈ 0) was weighed and rejected.
Sealed prediction P5 (PROMOTE, ~55%) scores as a **hit**.

Three mechanical pre-merge fixes were assigned:

- **M1 — stale census-totals table in LAWS.md.** The header line was
  updated at build time but the per-module totals table was not:
  effect.mli direct claims 55 → 59, its covered registry rows 155 → 159,
  total covered 108 → 112, covered registry rows 236 → 240, unique
  properties 69 → 73.
- **M2 — fail-fast properties must enumerate every winner position.**
  The registered `par3`/`par4` fail-fast qcheck properties generated the
  failing position randomly; a position-specific regression could hide
  behind a lucky seed. Fix: the property generates only (error, base
  delay) and deterministically executes every position (3 / 4 cases per
  run), so each run covers all documented branches.
- **M3 — footprint aggregation test must discriminate every child
  position.** The audit test's names discriminated all children but the
  capability flags did not (only child 1 carried a flag). Fix: each child
  carries a unique footprint-originating capability (par3:
  resources/logs/metrics; par4: resources/logs/metrics/background) and the
  test asserts the union, so a flag dropped from any position fails.

## Notes

- No design change; no new law-bearing prose (M1/M2/M3 are mechanical:
  totals correction, stronger generated coverage of the same claims,
  stronger assertion in an existing test). Registry rows M119–M122 and
  their named properties are unchanged in wording; M2 changes the
  properties' engines, not their statements.
- Gates to re-run after the fixes: native trio (`dune build @install`,
  `dune runtest --force`, `eta-oxcaml-test-shipped`) plus
  `dune runtest test/laws --force` explicitly.
- Scope fence unchanged; `followup-1.md` stays uncommitted.
