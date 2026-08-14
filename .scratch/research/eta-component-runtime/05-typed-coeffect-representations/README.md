# Compiler probe record

## Command

```sh
env XDG_CACHE_HOME=/tmp/eta-nix-cache \
  nix develop -c bash \
  .scratch/research/eta-component-runtime/05-typed-coeffect-representations/probes/run.sh
```

The shell reported OCaml `5.2.0+ox`. The script stores one complete compiler
result in `results/` for each source in `probes/`.

## Expected results

| Probe | Exit |
| --- | --- |
| `type_id_value_restriction.ml` | 2 |
| `type_id_annotated.ml` | 0 |
| `portability_type_id.ml` | 0 |
| `portability_object.ml` | 2 |
| `portability_package.ml` | 2 |

Negative probes are evidence. The script records their compiler diagnostics
and exits successfully after all five probes.
