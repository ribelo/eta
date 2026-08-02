# OCaml API syntax and ergonomics

Type: prototype
Status: open
Blocked by: 03, 04, 05, 07

## Question

What does ordinary Eta Crux application code look like after the semantic API
is known?

Build the same small dynamic application with the viable styles:

- plain functions and labeled arguments.
- `let*` and `let+` syntax over computations.
- local modules, first-class modules, or generative functors.
- a narrow PPX only where normal OCaml cannot express acceptable syntax or
  diagnostics.

Include local state, two independent child instances, a dynamic branch, keyed
children, one staged effect, and typed root output. Compare inferred signatures,
compiler errors, source locations, refactor behavior, and generated code.

Use OCaml strengths rather than reproducing another language's syntax. Do not
make a PPX part of V1 unless the prototype shows a concrete semantic or
diagnostic advantage.
