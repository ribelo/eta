# handled_effect R-channel verdict

## Status

Partial acceptance for scoped local handlers; rejected as an Eta R-channel
replacement.

This reopens V-R10/R-D and V-RN only for Jane Street's `handled_effect` package.
It does not change live Eta code.

## Source And Toolchain

- OxCaml shell: `nix develop .#oxcaml`, `ocamlc -version` = `5.2.0+ox`.
- Installed package: `handled_effect.v0.18~preview.130.91+190`.
- Upstream `oxcaml` branch inspected for API reading at commit
  `5d496b7edb81009be03d63b071616d3446d0c175`.

## What The Old Research Got Right

The old raw R-D falsifier was not "native effects are bad". It was narrower:
raw `Effect.perform Get_db` hides requirements from the type, and forgetting a
handler compiles and becomes `Effect.Unhandled`.

The old typed R-D follow-up also held: static evidence is possible, but it tends
to leak witnesses, token passing, or handler order into user signatures.

The effect-services locality lab found a separate failure mode: a
root-installed service handler does not automatically cover all Eio/Eta child
fiber boundaries.

## New Evidence

Positive:

- `fixtures/runtime_smoke.ml` proves two `handled_effect` service shapes can run
  the A/B/C story:
  - `Handled_combined`: one service effect with Db and Log operations.
  - `Handled_separate`: one effect per service with `run_with` forwarding.
- The same smoke keeps `Env_row_baseline` as the old V-R10 baseline.
- The smoke records that `Handled_combined.run_db_only` still turns missing Log
  into runtime behavior, not static provider evidence.

Negative:

- `neg_zero_arg_auto_di.ml`: `a` cannot call service leaves without handler
  arguments. The compiler expects `Log_eff.t Handled_effect.Handler.t`.
- `neg_escape_handler.ml`: a handler from `run` cannot escape; the compiler
  rejects local-to-global escape.
- `neg_continue_missing_forward_handler.ml`: omitting forwarded handlers from a
  continuation is rejected by the typed effect list.
- `neg_eio_fiber_capture.ml`: a local handler from `Handled_separate.run` cannot
  be captured by `Eio.Fiber.both` child closures because those closures must be
  global.

## Cross-Tab

| Criterion | R-B object-row env | Raw native effects | Typed request DSL | handled_effect combined | handled_effect separate |
| --- | --- | --- | --- | --- | --- |
| A body mentions zero services | yes | yes | yes | yes, if one generic handler is accepted | no, handler args are explicit |
| A argument list mentions zero services/handlers | yes | yes | no for typed variants | no, one handler | no, Db and Log handlers |
| Type carries transitive requirements | yes, object row | no | yes, via witnesses/tokens | no per-service evidence | yes, via handler args/effect list |
| Missing provider static failure | yes, boot object lacks method | no | yes | no if operations share one effect | yes for missing handler plumbing |
| Handler escape safety | not applicable | no static handler token | token-dependent | yes, local handler cannot escape | yes, local handler cannot escape |
| Eio child fiber root-handler story | ordinary values can be passed intentionally | old runtime locality failure | token/wrapper-dependent | not tested as winner | local handler capture rejected |
| User-visible dependency language | object methods | hidden runtime operations | witnesses/tokens/HLists | one generic handler | local handler args and typed lists |
| Verdict | remains baseline | rejected | rejected/dominated | useful locally, not R-channel | useful locally, not R-channel |

## Decision Diary

### V-HE1 - `handled_effect` fixes raw unhandled-handler unsafety locally

Status: ACCEPT.

Decision: For code written in the `handled_effect` style, operations cannot be
performed unless the caller has a handler value. Local mode also prevents the
handler from escaping its installed scope.

Evidence: `runtime_smoke.ml` passes; `neg_escape_handler.ml` rejects returning a
handler from `run`.

Counterevidence considered: the combined service effect can still encode
missing Log as a runtime branch if multiple services are collapsed into one
effect. The safety is strongest when each service is a separate effect.

Recommendation: treat `handled_effect` as strong prior art for scoped local
control effects.

Confidence: High for scoped handlers.

Would change if: a realistic Eta integration required handler values to escape
or be stored and could still prove safety.

### V-HE2 - `handled_effect` does not preserve the Eta R-channel dividend

Status: REJECT as R-channel replacement.

Decision: Do not replace Eta's object-row `'env` channel with `handled_effect`.

Evidence: `neg_zero_arg_auto_di.ml` shows the strongest separate-service shape
requires explicit local handler arguments. The accepted signature in
`Handled_separate.A_SIG` is:

```ocaml
val a : Db_eff.Handler.t @ local -> Log_eff.Handler.t @ local -> string -> int
```

That fails V-R10's success bar: `a`'s argument list must mention zero services
or service machinery while its inferred type carries transitive requirements.

Counterevidence considered: this explicitness is exactly what gives
`handled_effect` static safety. It is a good tradeoff for local algebraic
effects, but not for Eta's R-channel goal.

Recommendation: keep object-row env as the Eta R-channel shape.

Confidence: High for the tested A/B/C story.

Would change if: a `handled_effect` wrapper can hide handler values from `a`'s
argument list while preserving per-service static provider evidence and no
runtime `Unhandled` path.

### V-HE3 - `handled_effect` partially addresses locality by rejecting unsafe capture

Status: PARTIAL.

Decision: The old root-handler locality failure is not reproduced as a runtime
`Effect.Unhandled`; instead OxCaml rejects capturing the local handler into
global Eio child closures.

Evidence: `neg_eio_fiber_capture.ml` rejects using `db_h` inside
`Eio.Fiber.both` closures because the value is local and the closures are
global.

Rationale: This is safer than raw effects, but it means a root-installed generic
service handler still does not transparently cover Eta/Eio child fibers.
Cross-fiber use needs an explicit wrapper/re-run strategy at the fork boundary,
which was already the old locality constraint.

Recommendation: do not revive generic native-effect-backed Eta services on this
evidence. A narrower Eta-owned API could still be studied separately.

Confidence: Medium. This tests Eio `Fiber.both`, not Eta `Supervisor.scoped`,
because this standalone lab does not link the local Eta package.

Would change if: Eta gains an internal mechanism to reinstall/forward
`handled_effect` handlers at runtime-owned fiber boundaries without exposing
handler arguments to user code.

## Commands Run

```sh
nix develop .#oxcaml -c opam install handled_effect --yes --assume-depexts
nix develop .#oxcaml -c bash -lc 'cd .scratch/evidence/handled_effect_r_channel && dune build --root . ./fixtures/runtime_smoke.exe && _build/default/fixtures/runtime_smoke.exe'
nix develop .#oxcaml -c bash -lc 'cd .scratch/evidence/handled_effect_r_channel && HANDLED_EFFECT_NEG=zero_arg_auto_di dune build --root . ./fixtures/neg_zero_arg_auto_di.exe'
nix develop .#oxcaml -c bash -lc 'cd .scratch/evidence/handled_effect_r_channel && HANDLED_EFFECT_NEG=escape_handler dune build --root . ./fixtures/neg_escape_handler.exe'
nix develop .#oxcaml -c bash -lc 'cd .scratch/evidence/handled_effect_r_channel && HANDLED_EFFECT_NEG=continue_missing_forward_handler dune build --root . ./fixtures/neg_continue_missing_forward_handler.exe'
nix develop .#oxcaml -c bash -lc 'cd .scratch/evidence/handled_effect_r_channel && HANDLED_EFFECT_NEG=eio_fiber_capture dune build --root . ./fixtures/neg_eio_fiber_capture.exe'
```

The negative commands exited non-zero with the expected compiler diagnostics.

One-command repeat:

```sh
nix develop .#oxcaml -c bash .scratch/evidence/handled_effect_r_channel/run.sh
```

## Deferred

- A direct Eta `Supervisor.scoped` fixture linked against local Eta from this
  standalone lab. The Eio closure-mode failure is already enough to avoid
  accepting generic service effects, but a future Eta-owned handler propagation
  design should test Supervisor explicitly.
- A wrapper design that re-runs or forwards handlers at selected fiber
  boundaries. This would be a new candidate, not evidence that the current
  `handled_effect` shape preserves V-R10.
