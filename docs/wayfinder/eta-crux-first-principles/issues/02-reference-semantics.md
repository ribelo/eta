# Reference semantics worth keeping

Type: research
Status: claimed

## Question

Which reference semantics belong in Eta Crux? Which exist only because of the
original language, renderer, runtime, or deployment boundary?

Use primary source code and official documentation. At minimum, examine:

- Bonsai typed computations, state machines, action injection, dynamic
  branching, keyed `assoc`, lifecycle, and effect delivery.
- Incremental graph ownership, stabilization, necessity, cutoffs, dynamic
  scopes, and keyed collection support.
- Elm update, command, subscription, and runtime ordering.
- Rust Crux core/shell ownership, effects, requests, capabilities, testing, and
  serialization boundaries.

Record the smallest coherent semantic subset that supports the direction in
[Eta Crux first-principles direction](01-eta-crux-direction.md). Separate
semantic laws from API spelling and implementation machinery. Identify every
claim that current Eta Crux notes copied without enough justification.

Write one durable research report under `.scratch/research/eta-crux/` and link
it from the answer.
