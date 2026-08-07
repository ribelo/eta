# Integrated finalist checkpoint

Date: 2026-08-07

## Purpose

This checkpoint preserves the implementation work for issue 11.
The final issue decision rejects this finalist on performance.

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
- Signal model: 21 of 21
- generated Signal properties: 40 of 40
- lifecycle and timer behavior: 64 of 64
- finalist-native replacement checks: 3 of 3
- public negative compilation fixtures
- root reclamation

The complete scratch project builds with:

```sh
nix develop -c dune build --root \
  .scratch/research/eta-signal-execution-model/integrated-finalist-probe \
  --profile release @all
```

The complete behavior gate passes with:

```sh
env BUILD_TIMEOUT=300s SUITE_TIMEOUT=120s \
  nix develop -c \
  .scratch/research/eta-signal-execution-model/integrated-finalist-probe/run.sh \
  tests
```

The fresh factory remains the selected candidate.
The behavior gate does not route cases to the legacy control.

## Raw performance checkpoint

`raw-smoke.tsv` contains one early CPU-pinned pair with one sample.
It remains diagnostic evidence.

Every raw row passes its correctness and allocation check.
Most wall-time rows pass in this pair.
Depth 100 and cutoff exceed the paired `1.20` wall-time limit.

`raw-keyed-smoke.tsv` contains a later keyed-only pair.
All six keyed rows pass correctness, allocation, and wall-time checks in that pair.

`matched-results.csv` and `matched-summary.csv` contain the final matched matrix.
Every complete public row fails in all three pairs.

`edge-results.csv` and `edge-summary.csv` contain the final Eta-only matrix.
Dynamic-scope cleanup and observer disposal fail.

## Next work

1. Promote this implementation as the production pre-alpha base.
2. Remove repeated public execution crossings in production.
3. Remove graph-history work from dynamic cleanup and observer disposal.
