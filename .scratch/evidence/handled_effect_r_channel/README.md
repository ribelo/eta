# handled_effect R-channel reopening

This lab reopens the native algebraic-effect service/R-channel research for
Jane Street's `handled_effect` package.

Old falsifiers:

- Raw OCaml effects hid service requirements from the type and moved missing
  providers to `Effect.Unhandled`.
- A typed request DSL recovered static evidence only by exposing witnesses,
  handler order, or lexical tokens in user signatures.
- Root-installed native service handlers did not survive all Eio/Eta fiber
  boundaries, especially Eta-owned supervisor children.

Question:

Can `handled_effect` address those failures while preserving Eta's R-channel
success bar: a function `a` calls `b` and `c`, mentions no services in its body
or argument list, its type carries transitive requirements, and missing
providers fail before uncontrolled runtime execution?

## Proof Questions

| # | Proof question | Evidence needed | Risk | Status |
| --- | --- | --- | --- | --- |
| P1 | Can `handled_effect` express the service story? | Runtime positive fixture | Medium | See `fixtures/runtime_smoke.ml` |
| P2 | Does it reject missing handlers mechanically? | Compile-negative fixtures | High | See `neg_*.ml` |
| P3 | Does it preserve R-channel zero-service argument shape? | Signature/negative fixture | High | See `neg_zero_arg_auto_di.ml` |
| P4 | Does it avoid the old fiber-local root-handler issue? | Eio capture negative/diagnostic | Medium | See `neg_eio_fiber_capture.ml` |

## Commands

```sh
nix develop .#oxcaml -c opam install handled_effect --yes --assume-depexts
nix develop .#oxcaml -c bash .scratch/evidence/handled_effect_r_channel/run.sh
```
