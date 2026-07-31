# One public API across both state backends

Type: prototype
Status: open
Blocked by: 01

## Question

One public API with the backend chosen at construction is the preferred shape — the same
cell, output and driver surface, with graph-only operations simply absent under plain state
— but whether it actually works in OCaml without leaking is unresolved.

Build a cheap `.mli` sketch to react to, and answer:

- Can one surface carry both backends with graph-only operations **absent** rather than
  present-and-failing? A graph-only operation that exists and fails at runtime under plain
  state violates the repository's break-loudly rule, so present-and-failing is not an
  acceptable answer.
- Where does the backend choice live in the types: a functor over a backend signature, a
  phantom parameter on the application and cell types, or two constructors returning the
  same abstract handle? Note two existing constraints: the app-facing API keeps functors
  out and threads a value instead, and dynamic structure forbids applying a functor at
  runtime inside a scope.
- Does the plain backend's lack of a computation-value type collapse the cell-result and
  output types, or do both stay uniform across backends?
- What does the test-harness surface look like across both backends?

Link the sketch as an asset from this ticket rather than pasting it in. If a single API
proves untenable, say so plainly and state the cheapest honest alternative.
