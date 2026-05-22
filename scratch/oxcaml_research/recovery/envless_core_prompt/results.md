# Envless portable core prompt research

Date: 2026-05-22

This was originally misattributed to Effet-OxCaml-9vo before the real ticket was
found. It is retained as standalone recovery research for the journal prompt:

> Dragging an Env-type argument through all effects should be removed. Effect
> shouldn't and can't build a graph like ZIO, so it shouldn't pretend it can.
> Simple argument passing is much more idiomatic in OCaml.

## Question

Should the new portable core keep the ZIO-shaped ('env, 'err, 'a) t, or should
dependencies be ordinary OCaml values captured by portable thunks and
effect-builder functions?

## Candidates

| Candidate | Status | Evidence |
| --- | --- | --- |
| A. Env-parameterized portable core | Viable but dominated | env_parameterized_baseline_positive.ml compiles and runs across Parallel_scheduler, but every thunk and interpreter call must drag the synthetic env type and runtime env argument. |
| B. Envless portable core with ordinary argument passing | Accepted | envless_argument_passing_positive.ml compiles and runs across Parallel_scheduler with two effect type parameters and no runtime env. |
| C. Remove env from current same-domain Effect.t now | Deferred | Existing public API is explicitly ('env, 'err, 'a) Effect.t; changing it is a compatibility migration, not required to prove the fresh portable core shape. |

## Evidence

Command:

    nix develop -c bash scratch/oxcaml_research/recovery/envless_core_prompt/run.sh

Result:

    candidate=A env_parameterized portable=true effect_type_params=3 runtime_env=true result_sum=95
    PASS expected-pass env_parameterized_baseline_positive
    candidate=B envless ordinary_args=true portable=true effect_type_params=2 runtime_env=false result_sum=95
    PASS expected-pass envless_argument_passing_positive
    PASS expected-fail envless_ref_capture_negative
    PASS expected-fail envless_eio_capture_negative
    summary: pass=4 fail=0

Negative boundary checks:

- Capturing a mutable ref inside an envless portable thunk fails because the
  thunk is expected to be portable and the ref use is not uncontended.
- Calling Eio.Time.now inside an envless portable thunk fails because the Eio
  operation is nonportable. The envless shape does not weaken the Stage A
  boundary.

## Verdict

Use candidate B for the fresh portable core:

    type ('err, 'a) Effect_portable.t
    val thunk : string -> (unit -> 'a) @@ portable -> ('err, 'a) Effect_portable.t

Dependencies should be ordinary OCaml arguments to effect builders:

    val program : clock -> random -> (error, int) Effect_portable.t

This keeps the compiler-enforced portable boundary from Stage A while removing
the fake graph-wide environment from the new core. Capability records remain
useful as ordinary values when a caller wants to bundle arguments, but they are
not a type parameter of every effect node.

## Would Change If

Reopen this if a portable interpreter feature needs graph-wide dependency
analysis that cannot be represented by ordinary OCaml argument passing. Current
evidence shows no such need: the portable AST needs typed error and result
channels, cancellation polling, and online queues, not a ZIO-like requirement
channel.
