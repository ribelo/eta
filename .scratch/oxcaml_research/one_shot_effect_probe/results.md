# One-shot Effect representation probe results

Command:

```sh
nix develop .#oxcaml -c bash scratch/oxcaml_research/one_shot_effect_probe/run.sh
```

Last result: `summary: pass=3 fail=0`.

## Fixtures

- `core_one_shot_positive.ml`: passes. A one-shot interpreter-function shape expresses `pure`, `fail`, `thunk`, `bind`, `map`, `catch`, `acquire_release`, and `run`. The resource callback is accepted as `@ once`, release runs once, and the final value is returned through the typed-failure result.
- `reuse_negative.ml`: expected compile failure. Reusing a resource-owning program after the first `run` is rejected with `This value is used here, but it is defined as once and has already been used`.
- `double_release_negative.ml`: expected compile failure. A resource interpreter that calls the same `@ once` release callback twice is rejected with the same once-use diagnostic.

## Decision signal

This probe strengthens the Phase 2 result: the viable path for static once-mode finalizers is not a local patch to the current reusable data GADT. The compiler enforces the desired resource invariant when the effect program is represented as a one-shot interpreter function consumed by `run`.

A plain `pure` interpreter function remains reusable if it captures no one-shot resource. The relevant invariant is therefore not that every expression of type `Effect.t` is inherently linear, but that resource-owning programs become one-shot and `Runtime.run` consumes them.
