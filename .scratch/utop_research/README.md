# Eta UTop Convenience Research

## Question

Find the smallest Eta-owned helper that makes interactive UTop use convenient
without adding REPL-only dependencies to the root eta package.

## Proof Obligations

| # | Proof question | Evidence needed | Risk | Status |
| --- | --- | --- | --- | --- |
| 001 | Can a user run a simple effect from UTop with one function call? | dune utop lib/utop returned Eta.Exit.Ok 42. | High | Proven |
| 002 | Can the helper preserve Eta's full Exit.t instead of secretly throwing? | Compiled and UTop fixtures use Eta_utop.run, which returns Eta.Exit.t. | High | Proven |
| 003 | Can blocking work use the host Eio substrate from the REPL? | Compiled smoke and UTop phrase both called Eta.Effect.blocking successfully. | Medium | Proven |
| 004 | Can the root eta package avoid a new eio_main/UTop dependency? | eta.opam remains unchanged; eta_utop.opam owns the eio_main dependency. | Medium | Proven |

## Candidate Ledger

| Candidate | Why plausible | Evidence needed to win | Evidence that would falsify it | Status |
| --- | --- | --- | --- | --- |
| A. Document Runtime.run_host_eio only | Already exists and is explicit. | UTop call site is acceptable. | Repeated Eio_main.run/Switch.run boilerplate remains at every call site. | Dominated |
| B. Add Eta_utop.run optional package | Keeps core Eta clean and gives a one-call REPL runner. | Build, UTop phrase, blocking smoke. | Requires root eta to depend on REPL packages or hides typed exits. | Accepted |
| C. Add Eta.Runtime.run_main to root Eta | Single namespace is discoverable. | Same smoke evidence as B. | Adds eio_main to root eta, violating install-only-what-you-use. | Rejected |

## Current Verdict

Candidate B wins. eta_utop is a separate optional package with one-call
helpers for interactive use:

```ocaml
Eta_utop.run (Eta.Effect.pure 42);;
Eta_utop.run_exn (Eta.Effect.map (( + ) 1) (Eta.Effect.pure 42));;
```

The root eta package remains free of eio_main and utop.
