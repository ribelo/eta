# Eta supervised work substrate

Type: prototype
Status: resolved
Blocked by: 06, 07

## Question

Which Eta-owned substrate satisfies Eta Crux work ownership and post-commit
admission without duplicating general runtime machinery?

## Answer

The [authoritative Eta map](https://github.com/ribelo/eta/blob/0cb86d09/docs/wayfinder/eta-supervised-work-substrate/map.md)
owns this decision. Its prototypes proved one gap in current public composition.
Eta cannot mark a point after a child cancellation request and before child
settlement.

The selected addition is:

```ocaml
val request_cancel :
  ('s, 'err, 'a) child -> ('s, unit, 'outer_err) Scope.t
```

The [production contract](https://github.com/ribelo/eta/blob/0cb86d09/docs/wayfinder/eta-supervised-work-substrate/issues/03-production-request-cancellation-contract.md)
defines the request point, races, causes, backend duties, laws, and test gates.

Eta Crux composes that operation with existing Eta primitives. Post-commit start
registers gated activation and transition work before any new body starts. It
then requests cancellation for every removed subtree. After every request
returns, it releases activation work and then transition work.

Old cleanup can overlap released work. A later `cancel`, `await`, or supervisor
scope exit supplies settlement. Final root shutdown keeps the stronger complete
settlement fence.

The public-composition evidence is at commit `33e6c918`. The selected-interface
evidence is at commit `f90f8232`. Both prototypes passed the OxCaml and upstream
OCaml gates.

Eta Crux adds no private scheduler, cancellation tree, runtime scope, or detach
operation. Eta implements the contract at commit `f745846d`, with final law
spans at `c18fa277`. The archived production evidence is in
[`docs/issues/archive/eta-supervised-work-substrate.md`](../../../issues/archive/eta-supervised-work-substrate.md).
