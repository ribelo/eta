# Dynamic topology probe

This directory contains throwaway research code.
It does not contain production Signal code.

The probe compares three private topology models:

1. a chronological inverse-action journal
2. owner-local shadow capsules
3. immutable whole-topology replacement

The complete checks cover bind identity, scope invalidation, demand transfer,
keyed continuity, persistent output roots, rollback, affected-only work, and
constant-time commit.

Run the checks:

```sh
nix develop -c bash -lc '
  dune build --profile release @install
  export OCAMLPATH="$PWD/_build/install/default/lib"
  dune build --root \
    .scratch/research/eta-signal-execution-model/dynamic-topology-probe \
    --profile release probe.exe
  .scratch/research/eta-signal-execution-model/dynamic-topology-probe/_build/default/probe.exe \
    --check
'
```

Run the three-pair measurements:

```sh
nix develop -c bash \
  .scratch/research/eta-signal-execution-model/dynamic-topology-probe/run.sh
```

The candidate uses integer values and `Stdlib.Map`.
It does not implement generic typed nodes, observers, timers, Effect, or Eio.
The Eta reference row provides edge-path context at the current public seam.
