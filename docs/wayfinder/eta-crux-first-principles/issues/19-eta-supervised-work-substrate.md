# Eta supervised work substrate

Type: prototype
Status: claimed
Blocked by: 06, 07

## Question

Can current Eta primitives implement Eta Crux work ownership and post-commit
admission without duplicating general runtime machinery?

Prototype one root work manager with nested child groups. It must demonstrate:

- a parent-owned group that accepts work across several advancements.
- nested group creation, subtree cancellation, and complete settlement.
- atomic registration before any admitted effect body starts.
- ordered release for deactivation, activation, and transition groups.
- concurrent sibling work after release.
- first-terminal-outcome races and complete `Eta.Cause` preservation.
- shutdown that returns with no owned work or resources.
- the same semantic surface under OxCaml and upstream OCaml runtimes.

Compare `Eta.Supervisor.scoped`, `Supervisor.Scope`, `Effect.all`, and
`Runtime.drain`. Keep Eta Crux graph identities and advancement state out of Eta.

If existing primitives cannot express the contract, propose the smallest
general Eta addition. Test managed task groups and atomic supervisor admission
before adding a Crux-private scheduler, scope handle, or cancellation tree.

The result must remain backend-neutral and preserve structured ownership. It
must not expose Eio switches, runtime-contract tokens, or an unscoped detach
operation.
