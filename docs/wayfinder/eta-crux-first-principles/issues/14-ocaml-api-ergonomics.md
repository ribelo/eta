# OCaml API syntax and ergonomics

Type: prototype
Status: claimed
Blocked by: 03, 04, 05, 07, 08, 11

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
children, one staged effect, one source, and typed root output. Compare inferred
signatures, compiler errors, source locations, refactor behavior, and generated
code.

Prototype a clear surface for the two-phase source producer, spec equality,
changing mappers, terminal outcomes, and the target endpoint. Keep readiness in
the type structure instead of an application callback. Compare the rank-2
emitter record with any equally precise, simpler syntax.

Also fix the exact surface for `Endpoint.admission_error`, explicit handling in
typed-infallible staged effects, `Post_commit.start_result`, crash detection,
and final settlement. Include packed causes, trigger kinds, diagnostic snapshots,
and identity fields. The API must expose no public root typestate.

Use OCaml strengths rather than reproducing another language's syntax. Do not
make a PPX part of V1 unless the prototype shows a concrete semantic or
diagnostic advantage.
