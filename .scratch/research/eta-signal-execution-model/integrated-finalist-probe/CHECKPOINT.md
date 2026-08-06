# Integrated finalist checkpoint

Date: 2026-08-07

## Purpose

This checkpoint preserves the implementation work for issue 11.
It is not the final issue decision.

The research bundle contains three durable implementation layers:

1. `selected_core.ml` owns typed propagation, rollback, slots, bind, and keyed work.
2. `selected_edges.ml` owns observer and timer edge protocols.
3. `selected_factory_fresh.ml` adapts the selected layers to the public Signal interface.

`finalist_factory.ml` is an earlier full-interface control.
It adapts the existing engine structure and is not the selected candidate.
Keep it as implementation and migration evidence.

## Passing checks

The selected core passes these checks:

- heterogeneous typed propagation and physical rollback
- static, bind, keyed, and slot lifecycle behavior
- allocation and affected-work checks
- weak root reclamation and generation-safe slot reuse
- randomized directed-acyclic-graph traces

The selected edge driver passes these checks:

- observer ordering, failure, retry, acknowledgement, and disposal
- timer provenance, generations, retries, and late-wake fences
- cleanup aggregation and affected-only timer claims

The fresh public factory passes these suites:

- public Signal: 14 of 14
- Signal contract: 49 of 49
- persistent Signal Map: 12 of 12
- keyed Signal Map: 6 of 6
- Signal Stream: 18 of 18
- finalist-native replacement checks: 3 of 3
- public negative compilation fixtures
- root reclamation

The complete scratch project builds with:

```sh
nix develop -c dune build --root \
  .scratch/research/eta-signal-execution-model/integrated-finalist-probe \
  --profile release @all
```

## Remaining behavior work

The model suite currently passes 15 of 21 tests.
The remaining failures cover scripted traces, timer-bind demand, nested bind churn, diamonds, and generated graph traces.

The property suite has a seed-sensitive failure in the combined Signal script.

The main lifecycle suite still has failures in these areas:

- observer registration interruption
- timer startup rollback
- nested runtime operations
- timer catch-up and saturation
- disposal before timer-cancel installation

The fresh factory remains the only candidate for further fixes.
Do not route these cases to the legacy control.

## Raw performance checkpoint

`raw-smoke.tsv` contains one CPU-pinned pair with one sample for all raw rows.
It is diagnostic evidence, not the final three-pair decision.

Every raw row passes its correctness and allocation check.
Most wall-time rows pass in this pair.
Depth 100 and cutoff exceed the paired `1.20` wall-time limit.

`raw-keyed-smoke.tsv` contains a later keyed-only pair.
All six keyed rows pass correctness, allocation, and wall-time checks in that pair.

The final proof must run nine samples in three fresh pairs after all behavior gates pass.

## Next work

1. Make every generated behavior suite pass with `selected_factory_fresh.ml`.
2. Remove the remaining lifecycle stalls and seed-sensitive failures.
3. Run the full raw and public performance matrix.
4. Record the issue 11 verdict only after those gates finish.
