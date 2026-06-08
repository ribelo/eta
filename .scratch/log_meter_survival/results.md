# Effet-9qk results

Command:

    nix develop -c dune exec scratch/log_meter_survival/runtime_smoke.exe

Result:

    log_meter_survival runtime smoke passed

## Findings

Branch B proves possibility: a log emitted through an ordinary Logs reporter can
read a fiber-local observation context and carry active trace/span IDs without
a Log AST constructor.

The result is not a deletion win:

- Branch A model: 72 LOC.
- Branch B model: 126 LOC.
- Branch B needs process-global Logs reporter installation.
- Branch B has no equivalent standard metrics dependency in the current shell;
  metrics require an Effet-local registry anyway.
- Existing effet-otel logger/meter tests would need body rewrites from
  Effect.log / Effect.metric_update to Logs.info / registry calls.

Recommendation: keep the AST nodes. They are small, effect-shaped, lazy until
runtime interpretation, runtime-scoped, and avoid global reporter state.

