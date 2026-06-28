# duration_survival

Effet-yp5 lab comparing the current `Duration.t` newtype with an `int_ms` branch.

The int branch needs less API surface, but it allows bare integers at every time
boundary. The current `Duration.t` catches `Effect.delay 3`-style unit mistakes
and keeps call sites self-documenting (`Duration.seconds 5`, `Duration.ms 100`).

Verification:

```sh
nix develop -c dune exec .scratch/research/evidence/duration_survival/runtime_smoke.exe
```
