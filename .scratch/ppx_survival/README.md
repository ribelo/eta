# ppx_survival

Effet-vp8 survival lab.

`explicit_idiom_fixture.ml` contains 20 representative functions written with
the explicit `Effect.fn __POS__ __FUNCTION__ body` idiom. The repetition is
real but mechanical: one wrapper per instrumented public function.

`golden_cases.ml` is preprocessed by `ppx_effet`; inspect
`_build/default/scratch/ppx_survival/golden_cases.pp.ml` after build for the
expanded shape. It covers top-level functions, nested functions, anonymous
lambdas, local modules, partial application, thunk leaves, and env builder
expansion.

Verification:

```sh
nix develop -c dune exec scratch/ppx_survival/runtime_smoke.exe
```
