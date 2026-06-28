# Eta Effect Soundness Fixtures

## Purpose

The in-tree soundness suite compiles each fixture as a negative test and
expects OxCaml mode checking to reject it. All active Eta fixtures reject for
mode-safety reasons.

Command:

```sh
nix develop -c dune runtest test/eta --force
```

| Fixture | Expected result | Status |
| --- | --- | --- |
| effect_domain_safe_spawn_negative.ml | compile-fail | pass |
| effect_portable_atomic_negative.ml | compile-fail | pass |
| eio_switch_domain_safe_spawn_negative.ml | compile-fail | pass |
| channel_domain_safe_spawn_negative.ml | compile-fail | pass |
| pool_domain_safe_spawn_negative.ml | compile-fail | pass |

No fixture compiled unexpectedly, so no Eta mode-bound follow-up was filed from
this pass.

The Portable.Atomic fixture uses a real handoff shape: publish an Effect.t with
compare_and_set, then attempt to read it from Domain.Safe.spawn.
