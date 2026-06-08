# H-Ops1 Build Timing

Date: 2026-05-24
Host shell: `nix develop`
Build target: `packages/eta-http`

## Commands

```sh
nix develop -c dune clean --build-dir _build_h_ops1_cold
time -p nix develop -c dune build --build-dir _build_h_ops1_cold packages/eta-http
time -p nix develop -c dune build --build-dir _build_h_ops1_cold packages/eta-http
```

## Results

| Run | Exit | real | user | sys | Notes |
| --- | --- | ---: | ---: | ---: | --- |
| separate build dir after clean | 0 | 5.25s | 34.22s | 10.69s | Compiled eta-http plus local dependencies into `_build_h_ops1_cold`. |
| immediate incremental rebuild | 0 | 0.30s | 0.16s | 0.07s | No rebuild work after initial artifact creation. |

The fresh build emitted existing OxCaml alerts from
`packages/eta/blocking_runtime.ml` around `Stdlib.Domain.spawn`. They are
not eta-http dependency failures, but they should stay visible in handoff
notes.

## Verdict

The build-time posture is acceptable for local development. The cold run is
single-digit seconds on this machine, and the incremental rebuild is
sub-second.
