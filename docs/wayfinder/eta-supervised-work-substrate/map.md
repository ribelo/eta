# Eta supervised work substrate map

## Destination

A proven verdict on Eta supervised work, with prototype evidence. If Eta has a
gap, the map produces an implementation-ready, backend-neutral Eta contract.

## Notes

This map owns the general Eta decision. Eta Crux supplies the first acceptance
scenario, but Eta Crux does not define the public Eta interface.

The source scenario is recorded at commit `843e3523` on branch
`docs/eta-crux-requirements`. Its source tickets are **Deterministic advancement
transaction**, **Dynamic lifetime and work ownership**, and **Eta supervised
work substrate**.

The investigation derives general Eta requirements from that scenario. It must
trace each Eta Crux demonstration to a general requirement and visible evidence.

The map includes throwaway prototype work. It does not include production
implementation. First use only current public Eta APIs. Add an interface only
after the prototype proves the first impossible operation.

Keep Eta Crux graph identity, advancement state, and typed output out of Eta.
Do not expose Eio switches, runtime-contract tokens, or an unscoped detach
operation.

Run prototype gates through the repository OxCaml Nix shell. Preserve complete
`Eta.Cause` values in failure evidence.

Use `$prototype`, `$eio`, `$codebase-design`, `$oxcaml`, and `$simple-english`
when they apply. Do not use a research subagent without explicit approval.

The Eta decision frontier is clear. The three resolved tickets cover public
composition, the minimum interface, and the complete production contract.
**Eta supervised work substrate** in the Eta Crux map now points to this
authoritative decision. The integration is recorded at commit `878dcdca` on
branch `docs/eta-crux-requirements`. That commit also binds **Deterministic
advancement transaction** and **Dynamic lifetime and work ownership** to gated
registration, `Supervisor.Scope.request_cancel`, and the later settlement fence.

## Decisions so far

- [Current public composition verdict](issues/01-current-public-composition.md) — Public composition covers ownership, admission, causes, and shutdown, but it has no request-only cancellation point before settlement.
- [Minimal general supervised-work interface](issues/02-minimal-general-interface.md) — Add `Supervisor.Scope.request_cancel` and keep `cancel` as the settlement and failure fence.
- [Production request-cancellation contract](issues/03-production-request-cancellation-contract.md) — A request latches before return without waiting for settlement. Existing `cancel`, `await`, cause, ownership, and backend boundaries remain intact.

## Not yet specified

## Closure

Status: closed

The destination is complete. Current public composition proves one precise gap.
The selected operation closes that gap without widening Eta ownership.

The preserved prototype evidence is:

- `prototype/eta-supervised-work-current-composition` at results commit
  `33e6c918`, with code commit `ecd42b35`.
- `prototype/eta-supervised-work-minimal-interface` at results commit
  `f90f8232`, with candidate commit `25599df1`.

Both result bundles record status `0` under OCaml `5.2.0+ox` and OCaml `5.4.1`.
Their ticket answers record the exact Nix commands and visible results.

The production contract records the public laws, backend duties, negative type
checks, executable test names, registry rows, and production verification gates.
Production implementation remains outside this map.

All effort-owned changes are committed. The map and both prototype worktrees
were clean at closure. The shared Crux worktree retained only an unrelated
pre-existing modification outside this effort.

## Out of scope

- Production implementation of an Eta interface.
- Eta Crux computation structure, identity, advancement, and typed output.
- Eta Crux production implementation.
- A broad redesign of Eta supervision without evidence that the contract needs
  it.
- Compatibility paths, fallback behavior, and unscoped work escape.
