# Effet Resource portable-state probe results

Command:

```sh
nix develop .#oxcaml -c bash scratch/oxcaml_research/effet_resource_probe/run.sh
```

Last result: `summary: pass=3 fail=0`.

## Fixtures

- `effet_resource_portable_probe.ml`: passes. A Resource-shaped implementation with `value : 'a option Portable.Atomic.t` and `failures : 'err Cause.t list Portable.Atomic.t` works for ordinary Effet load/get/refresh behavior and for a two-domain Parallel refresh smoke test over immutable payloads.
- `effect_map_payload_negative.ml`: expected compile failure. A current Effect-shaped `map : ('a -> 'b) -> ...` callback cannot store its callback argument in `Portable.Atomic`; OxCaml reports the value is nonportable where `Some value` must be portable.
- `open_variant_error_negative.ml`: expected compile failure. Open polymorphic variant errors such as `[> \`Refresh_failed of string]` are not `immutable_data`, so they cannot be used directly as the portable Resource failure payload.

## Decision signal

Resource can become `Portable.Atomic`-backed only after the effect payload boundary is mode-aware. The standalone positive fixture proves the target state shape is viable; the negative fixtures explain why moving the shipped `packages/effet/resource.ml` implementation now breaks at the current `Effect.map` and open-polymorphic-variant boundaries.

This makes Phase 7 dependent on the Phase 4 Effect.t rewrite, or on a deliberate API break that closes/portable-annotates Resource error and value payloads before they enter Resource state.
