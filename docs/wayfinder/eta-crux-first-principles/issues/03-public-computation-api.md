# Public computation and construction API

Type: prototype
Status: open
Blocked by: 02

## Question

What public OCaml API represents a typed changing computation while keeping
`eta_signal` private? The computation can allocate state, injection, lifecycle,
and child computations.

Produce small `.mli` sketches for the strongest candidates. Compare:

- one public `'a t` plus an explicit or threaded construction context.
- separate public value and structural-computation types.
- a single computation type that hides both distinctions.
- explicit graph arguments, generative modules, and rank-2 or first-class module
  encodings where they improve safety.

The sketch must show pure mapping, applicative composition, dynamic `bind`, one
state machine, one child computation, and root construction. Invalid
cross-application composition must fail in types. Application code must not see
raw signals, observers, stabilization, or private graph scopes.

Judge the candidates by call-site clarity, inferred types, error messages,
dynamic construction, and the amount of engine machinery exposed. Link the
prototype assets from the answer.
