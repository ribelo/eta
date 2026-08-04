# Eta Crux performance-gate prototype results

## Scope

The prototype passed every modeled semantic and capacity check. It also emitted
the proposed statistics for all required scenario classes.

These measurements describe a small model. They do not describe Eta Crux
performance. The production implementation must establish the first baseline.

## Contract result

The prototype supports these decisions:

- V1 uses relative regression gates and deterministic gates.
- A wall-time row fails after a median increase of more than 15% in two of three
  full reruns.
- An allocation row fails after an increase of more than 5% and more than one
  word per operation.
- Reports contain the mean, standard deviation, median, p95, and allocation
  counters.
- A Git commit or tag identifies the baseline. The baseline and candidate use
  fresh runs from the same environment.
- Generated measurements remain local. No checked-in numeric result controls a
  gate.
- Standard keyed rows use 10,000 and 100,000 children.
- Disabled telemetry allocates the same number of words as the absent control.
- Disabled telemetry adds no more than 5% to the median wall time.
- The existing Eta benchmark runner owns the command. `dune runtest` does not
  run performance gates.
- Export and serialized-handle registries contain no more entries than live
  export nodes in the active session.

## Modeled measurements

The full prototype used 31 samples and 100,000 operations per sample. The
executable printed wall-time and allocation values for each scenario.

The values are useful only for checking the report format. Compiler
optimization can reduce a modeled operation to a few machine instructions.
Therefore, these values cannot set an Eta Crux baseline.

## Command

```sh
nix develop -c bash .scratch/prototypes/eta-crux-performance-gates/verify.sh
```
