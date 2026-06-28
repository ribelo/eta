# Eta dune utop REPL Evidence

## Question

Decide how Eta should support Exergy-style `dune utop` workflows where user
code runs under `Eio_main.run`, but Eta runtime combinators execute from the
compiled Eta libraries loaded by `dune utop <library>`.

## Current Verdict

Use one explicit host-substrate value, `Eta.Host_eio.t`, and route the Eta
operations that trigger Eio runtime effects through modules captured from the
same toplevel instance that installed `Eio_main.run`.

The compact Exergy shape is:

```ocaml
#require "eio_main";;

let host = Eta.Host_eio.make ~unix:(module Eio_unix) ~eio:(module Eio) ();;

Eio_main.run @@ fun env ->
Eio.Switch.run @@ fun sw ->
Eta_http.Client.run_host_h1 host ~sw
  ~clock:(Eio.Stdenv.clock env)
  ~net:(Eio.Stdenv.net env)
  ~random:(Eta.Capabilities.random_of_seed 1)
@@ fun client ->
existing_exergy_effect client
```

This keeps Exergy code on the normal `Eta_http.Client.t` API. The only REPL
setup is the host value and the host-backed runner.

## Proof Obligations

| # | Obligation | Evidence | Status |
| --- | --- | --- | --- |
| O1 | `Runtime.run (Effect.pure _)` works in `dune utop`. | Minimal fixture returned `Eta.Exit.Ok 42`. | Proven |
| O2 | Eta scoped/cancellation primitives work under the host runtime. | Host-backed runtime fixture using `delay`, `blocking`, and `for_each_par_bounded` returned `OK 2,3,4`. | Proven |
| O3 | Eta blocking uses the host worker substrate in `dune utop`. | Same fixture called `Eta.Effect.blocking` through `Runtime.run_host_eio` and completed. | Proven |
| O4 | eta-http one-shot H1 can use host DNS/TCP/TLS/body IO. | `dune utop lib/http` Yahoo fixture returned `Eta.Exit.Ok (429, 19)`, proving a normal HTTP response rather than `Effect.Unhandled`. | Proven |
| O5 | Exergy ingest can run unchanged with only REPL setup. | `dune utop lib/ingest` returned `OK fetched=0 skipped=0 failed=1 errors=1`; the remaining failure is ordinary provider/HTTP data, not `Cancel.Get_context`. | Proven |

## Candidate Ledger

| Candidate | Evidence | Status |
| --- | --- | --- |
| Link or require `eio_main` differently. | `dune utop lib/http -- -require eio_main` and Eta-side linking experiments still left compiled Eta calls raising `Cancel.Get_context`. | Rejected |
| Add a separate `eta.repl` or `eta.http.repl` package. | It would require Exergy to opt into a different library path and does not match the desired normal Eta API workflow. | Rejected |
| Only inject a host blocking runner. | Blocking then works, but eta-http still fails later at DNS/TLS/body operations and Eta parallel/scoped primitives still need host Eio calls. | Rejected as incomplete |
| Single `Eta.Host_eio.t` used by `Runtime.with_host_eio` and `Eta_http.Client.run_host_h1`. | Covers runtime sleep, blocking, frame binding, switch/fiber/cancel operations, DNS/connect, and TLS underlying flow IO. | Accepted |

## Design Notes

`Eta.Host_eio.t` deliberately captures modules rather than storing individual
closures for every operation. The failure mode is module identity: compiled Eta
calls can perform Eio effects that the toplevel-installed `Eio_main.run` handler
does not handle. Routing those calls through the host modules keeps the effect
handler and the operation constructors aligned.

The eta-http helper is one-shot H1. It avoids the pooled client ownership
fibers, creates a normal `Eta_http.Client.t`, and lets existing code run without
being rewritten against a REPL-only API.

## Representative Commands

Runtime fixture:

```sh
nix develop -c bash -lc 'printf "%s\\n" ... | dune utop lib/eta'
```

HTTP fixture:

```sh
nix develop -c bash -lc 'printf "%s\\n" ... | dune utop lib/http'
```

Exergy fixture:

```sh
cd /home/ribelo/projects/exergy
nix develop -c bash -lc 'printf "%s\\n" ... | dune utop lib/ingest'
```
