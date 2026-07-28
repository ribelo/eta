# S′ representation proof

S′ restores `describe` without restoring static-name storage:

- `lib/eta/effect_core.ml:68-74`: `Custom` has exactly two fields, `eval` and
  `leaf_name`.
- `lib/eta/effect_core.ml:587-610`: `describe` pattern-matches constructors and
  reads only `leaf_name` from `Custom`; it contains no reference to `names`.
- `lib/eta/effect.mli:812-815`: `Expert.make` retains only `?leaf_name` before
  its evaluator; there is no `?names` or audit declaration.
- A targeted search over `lib/eta/effect*.ml` and `effect.mli` finds no
  `~names`, `Custom.names`, `with_names`, or `collect_names`.
- `nix develop -c dune build @install` and the full native test gate compile
  this shape successfully; exact statuses are under `gates-sprime/`.

The follow-up stop condition is not met: `describe` needs no propagated names.
