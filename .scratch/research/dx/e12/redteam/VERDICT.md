# DX-E12 red-team verdict

## Opaque bind attack

`redteam_effect_audit.ml` constructs a handler whose visible blueprint is
`Bind(Pure, <bind …>)`. Its ordinary continuation returns `Effect.sleep`.
`Effect.audit` therefore reports `uses_clock=false`, while executing the
handler invokes the runtime sleeper once.

This is the intended disconfirming fixture, not a passing runtime-inventory
claim. The warning is present in the public `audit` type and value contracts,
the `describe` contract, and every `Eta_test` assertion contract: inspection
does not call ordinary continuation functions, and false flags cover only the
visible static spine plus declared library leaves. The API remains usable as a
static preflight but cannot honestly certify “never sleeps” for arbitrary bind
lambdas.

## `preserve` inheritance attack

The same executable wraps `Effect.sleep` in `Effect.uninterruptible`, a wrapper
implemented through `Effect_core.preserve` with no direct clock footprint. Its
audit still reports `uses_clock=true`, proving that `preserve` unions the inner
effect footprint instead of erasing it.

Run with:

```sh
nix develop -c bash .scratch/research/dx/e12/redteam/run.sh
```

Expected committed output is in `output.txt`.
