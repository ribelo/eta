# resource_survival

Survival lab for Effet-6yf.

- `branch_a_resource.ml` delegates to the current `Effet.Resource` API.
- `branch_b_atomic.ml` implements the same cached-loader behavior with an
  explicit `Atomic.t` cell plus Effect primitives.
- `runtime_smoke.ml` runs the existing Resource behavioral slice against both
  branches: manual refresh, failed refresh keeping last-good, scheduled
  auto-refresh, and auto failed refresh recording failure evidence.

Run:

    nix develop -c dune exec .scratch/research/evidence/resource_survival/runtime_smoke.exe
