# log_meter_survival

Deletion-pressure lab for Effet-9qk.

- `branch_a_ast.ml` models the current design: `Log` and `Metric_update` are
  eff AST constructors interpreted by the runtime.
- `branch_b_adapter.ml` models the adapter design: the eff AST has no log or
  metric constructors. Logs go through an ordinary `Logs` reporter; metrics go
  through a local registry. Both read the active span from a fiber-local runtime
  observation context.
- `runtime_smoke.ml` runs identical correlation fixtures against both branches.

Run:

    nix develop -c dune exec .scratch/research/evidence/log_meter_survival/runtime_smoke.exe
