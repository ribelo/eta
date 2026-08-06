# Eta Signal edge-protocol probe

This throwaway probe checks a timer and observer state model.
It also measures related reference operations through the pinned production
engine.

Run all checks and measurements:

```sh
.scratch/research/eta-signal-execution-model/edge-protocol-probe/run.sh
```

The probe models the selected private protocol. It does not implement the public
Signal API or replace the integrated acceptance run in issue 11.

The run script builds the repository `@install` target first. It then sets
`OCAMLPATH` to that build, so the reference executable cannot use a stale
installed `eta_signal` package.
