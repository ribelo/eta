# native_effects_research

Effet-9ey lab for the R-D native-effects candidate.

- `r_d_raw.ml` keeps the original raw OCaml 5 handler shape. It is ergonomic but
  missing handlers are runtime `Effect.Unhandled` failures.
- `r_d_typed.ml` contains two typed variants:
  - `Presence_set` tracks requested handlers with a phantom set and HList
    handler stack. It rejects missing handlers at `run`, but users must pass
    membership witnesses and maintain handler order.
  - `Scoped_token` requires lexical tokens from `with_db` / `with_log`. It
    rejects `ask` outside a handler, but every service-using function now takes
    explicit tokens.

Commands:

```sh
nix develop -c dune exec scratch/native_effects_research/runtime_smoke.exe
NATIVE_EFFECTS_NEG=presence_missing_handler nix develop -c dune build scratch/native_effects_research/neg_presence_missing_handler.exe
NATIVE_EFFECTS_NEG=token_ask_without_scope nix develop -c dune build scratch/native_effects_research/neg_token_ask_without_scope.exe
```
