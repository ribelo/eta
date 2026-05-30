# Eta UTop Convenience Verdict

## V-UTOP-1 - Ship An Optional Eta_utop Runner

Status: ACCEPT

Decision: add a separate eta_utop public library/package with Eta_utop.run,
Eta_utop.run_exn, Eta_utop.with_runtime, and Eta_utop.host.

Evidence:

- nix develop -c dune exec scratch/utop_research/runtime_smoke.exe returned OK pure, OK map, and OK blocking.
- dune utop lib/utop with scratch/utop_research/utop_smoke.ml returned Eta.Exit.Ok 42, 43, and Eta.Exit.Ok 7.
- eta.opam did not gain eio_main or utop; the generated eta_utop.opam owns eio_main.

Counterevidence considered:

- Runtime.run_host_eio is already explicit and general, but the UTop call site repeatedly exposes Eio_main.run, Eio.Switch.run, host construction, and clock extraction.
- Putting the helper in root Eta.Runtime would be more discoverable, but it would make core Eta depend on eio_main for a REPL-only convenience.

Recommendation for production:

Use Eta.Runtime.with_host_eio or an application-owned runtime in normal programs. Use Eta_utop.run from UTop when convenience is the goal.

Confidence: High for core Eta effects, including blocking. HTTP/provider-specific client helpers remain outside this slice.

Would change if: UTop-installed packages cannot require eta_utop after installation, or Exergy needs client construction helpers that cannot live in Exergy without duplicating Eta-owned runtime invariants.
