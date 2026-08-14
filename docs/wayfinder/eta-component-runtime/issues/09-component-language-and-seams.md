# Component language and seams

Type: grilling
Status: open
Blocked by: 03, 08

## Question

What canonical terms and module seams describe Eta components, component
instances, contexts, coeffects, providers, committed dependency views, and
desired state?

Keep `Component` and `component instance` as the approved declaration and
installation terms. Decide whether `Coeffect` is a public Eta term or only the
formal name for a dependency contract. Avoid collisions with Eta Runtime,
capabilities, services, scopes, and fibers.

Record the resolved domain terms in `CONTEXT.md`. Define the external seams
without selecting their final OCaml signatures.
