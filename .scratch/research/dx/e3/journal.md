# DX-E3 Journal — `race_either`

Branch: `research/dx-e1e2e3-hygiene`
Phase: B (hygiene)

Sealed predictions: `.scratch/research/dx/journal.md` §E3.

## Implementation

- `Effect.race_either left right` = `race [map Left left; map Right right]`.
- mli copies `race` permit-acquisition / resource caveat verbatim and states
  first argument = `` `Left ``, second = `` `Right ``.
- Parity tests: left/right winners, loser cancel, scoped permit release,
  loser finalizer diagnostic after winner.

## Gates

All required Nix gates PASS (see report). Focused core_eio: 508 tests PASS.
