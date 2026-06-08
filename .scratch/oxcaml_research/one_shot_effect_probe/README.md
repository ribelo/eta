# One-shot Effect representation probe

This lab checks whether Effet's reusable data GADT can be replaced, or staged
toward replacement, with a one-shot interpreter-function representation.

The question is narrow:

- can the shape express core combinators (`pure`, `fail`, `bind`, `map`,
  `catch`) plus `acquire_release`;
- can `Runtime.run` consume the final effect exactly once;
- can OxCaml reject accidental reuse of a one-shot effect or one-shot release.

Run with:

```sh
nix develop .#oxcaml -c bash scratch/oxcaml_research/one_shot_effect_probe/run.sh
```
