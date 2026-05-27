# Eta dune utop REPL Evidence

## Question

Decide how Eta should support Exergy-style `dune utop` workflows where user
code runs under `Eio_main.run`, but Eta runtime combinators execute from the
compiled Eta library loaded by `dune utop <library>`.

## Proof Obligations

| # | Obligation | Evidence | Status |
| --- | --- | --- | --- |
| O1 | `Runtime.run (Effect.pure _)` works in `dune utop`. | Previous committed fixture returned `Eta.Exit.Ok 42`. | Proven |
| O2 | `Effect.scoped` works in `dune utop`. | With fiberless scoped switch patch, `Eta.Runtime.run rt (Eta.Effect.scoped (Eta.Effect.pure 42))` returns `Eta.Exit.Ok 42`. | Proven for minimal scoped fixture |
| O3 | `Effect.Blocking.submit` works in `dune utop`. | With mutex/cancel guards, failure moves from `Cancel.Get_context` to `Eio_unix__Thread_pool.Run_in_systhread`. | Contradicted |
| O4 | A thread-per-job replacement using Eta-compiled `Eio.Promise.await` fixes blocking. | Temporary `run_systhread` using `Thread.create` + `Eio.Promise.await` fails with `Eio__core__Suspend.Suspend`. | Rejected |
| O5 | Linking `eio_main` into `lib/eta` fixes blocking. | Temporary `lib/eta/dune` dependency on `eio_main` still returns `Eta.Exit.Error (Cause.Die (Unhandled _))`. | Rejected |

## Candidate Ledger

| Candidate | Why plausible | Evidence needed to win | Current evidence | Status |
| --- | --- | --- | --- | --- |
| A. Guard only Eta frame/die-context/finalizer/scoped APIs in fiberless path | Minimal change; preserves normal Eio semantics when a current Eio fiber context exists. | `pure`, `scoped`, and tests pass; blocking either passes or is shown to need separate substrate work. | `pure` and `scoped` pass; blocking still fails later at worker dispatch. | Partial |
| B. Add `eio_main` as an Eta library dependency | Might force Eta and utop to use the same Eio backend instance. | Blocking fixture returns `Ok 43`. | Blocking fixture still fails. | Rejected |
| C. Replace Eta blocking worker wait with `Thread.create` + Eta-compiled `Eio.Promise.await` | Avoids `Eio_unix.Thread_pool.Run_in_systhread`. | Blocking fixture returns `Ok 43`; normal tests pass. | Fails at Eta-compiled `Eio__core__Suspend.Suspend`. | Rejected |
| D. Provide an explicit host-owned blocking substrate to Eta runtime/pool | Lets Exergy pass the Eio function from the same toplevel/backend instance that `Eio_main.run` handles. | A fixture passing the host runner returns `Ok 43`. | Host runner fixtures return `Eta.Exit.Ok 43` via `Runtime.create ~blocking_runner` and `Eta.Exit.Ok 44` via `Pool.create ~runner`. | Accepted |

## Verdict

V-UTOP-1 - Keep the fiberless `scoped` fix.
Status: ACCEPT
Decision: In a fiberless Eta root path, `Effect.scoped` should reuse the runtime
switch while preserving a fresh Eta finalizer list. In a normal Eio fiber, keep
`Eio.Switch.run`.
Evidence: Minimal `scoped (pure 42)` fixture returns `Eta.Exit.Ok 42`.
Counterevidence considered: This does not prove every scoped cancellation
interaction in utop, only the Exergy Yahoo fetch failure class where
`Eio.Switch.run` immediately trips `Cancel.Get_context`.
Confidence: Medium.

V-UTOP-2 - Do not claim blocking is fixed by mutex/cancel guards.
Status: REJECT PARTIAL AS COMPLETE FIX
Decision: Guarding `Mutex.use_rw ~protect:true` and `Cancel.protect` is
insufficient. It removes the first `Cancel.Get_context` failure but exposes
Eta's compiled `Eio_unix.Thread_pool.Run_in_systhread` effect as unhandled.
Evidence: `Effect.Blocking.submit ~name:"x" (fun () -> 43)` returns
`Eta.Exit.Error (Cause.Die (Unhandled Run_in_systhread))`.
Confidence: High.

V-UTOP-3 - Treat blocking as a substrate identity problem.
Status: ACCEPT
Decision: The remaining blocking fix needs a host-owned or otherwise same-backend
worker substrate, not another local guard around cancellation.
Evidence: Direct toplevel `Eio_unix.run_in_systhread` works, but Eta's compiled
`Blocking_runtime.submit` path performs an unhandled `Run_in_systhread`
effect. Eta-compiled `Eio.Promise.await` fails similarly at `Suspend`.
Confidence: Medium-high.

V-UTOP-4 - Add an explicit host-owned blocking runner.
Status: ACCEPT
Decision: Expose `Effect.Blocking.Pool.runner`, accept it on `Effect.Blocking.Pool.create`, and accept [?blocking_runner] on `Runtime.create` for the runtime-owned default blocking pool.
Evidence: In `dune utop lib/eta`, a runner value built from the host toplevel's `Eio_unix.run_in_systhread` returns `Eta.Exit.Ok 43` through `Runtime.create ~blocking_runner` and `Eta.Exit.Ok 44` through `Pool.create ~runner`.
Counterevidence considered: The default runner remains insufficient for this specific `dune utop <library>` loading shape; the fix is explicit rather than a silent fallback.
Confidence: High for the minimal Exergy REPL blocking failure class.

## Commands

Representative fixtures were run with:

```sh
nix develop -c dune utop --build-dir _build_eta_evidence lib/eta
```

The successful scoped fixture:

```ocaml
#require "eio_main";;
Eio_main.run @@ fun env ->
Eio.Switch.run @@ fun sw ->
let rt =
  Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
    ~random:(Eta.Capabilities.random_of_seed 1) ()
in
Eta.Runtime.run rt (Eta.Effect.scoped (Eta.Effect.pure 42));;
```

The failing blocking fixture:

```ocaml
#require "eio_main";;
Eio_main.run @@ fun env ->
Eio.Switch.run @@ fun sw ->
let rt =
  Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
    ~random:(Eta.Capabilities.random_of_seed 1) ()
in
Eta.Runtime.run rt
  (Eta.Effect.Blocking.submit ~name:"x" (fun () -> 43));;
```

The successful host-runner blocking fixture:

```ocaml
#require "eio_main";;
let runner =
  {
    Eta.Effect.Blocking.Pool.run_in_systhread =
      (fun ~label f -> Eio_unix.run_in_systhread ~label f);
  };;

Eio_main.run @@ fun env ->
Eio.Switch.run @@ fun sw ->
let rt =
  Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
    ~random:(Eta.Capabilities.random_of_seed 1)
    ~blocking_runner:runner ()
in
Eta.Runtime.run rt
  (Eta.Effect.scoped
    (Eta.Effect.Blocking.submit ~name:"x" (fun () -> 43)));;
```
