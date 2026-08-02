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

Run prototype gates through the repository Nix shells. Use both the OxCaml and
upstream OCaml tracks. Preserve complete `Eta.Cause` values in failure evidence.

Use `$prototype`, `$eio`, `$codebase-design`, `$oxcaml`, and `$simple-english`
when they apply. Do not use a research subagent without explicit approval.

After this map closes, **Eta supervised work substrate** in the Eta Crux map
becomes an integration pointer to the authoritative Eta decision.

## Decisions so far

## Not yet specified

- **Production contract.** The exact laws, backend obligations, negative type
  checks, executable tests, and package placement depend on the proven gap and
  the selected interface.

## Out of scope

- Production implementation of an Eta interface.
- Eta Crux computation structure, identity, advancement, and typed output.
- Eta Crux production implementation.
- A broad redesign of Eta supervision without evidence that the contract needs
  it.
- Compatibility paths, fallback behavior, and unscoped work escape.
