# Eio lifetime transfer

Type: research
Status: open
Blocked by:

## Question

Which Cordis temporal guarantees follow from Eio structured concurrency, and
which guarantees need a separate Eta component protocol?

Use primary Eio source, documentation, and tests for switches, cancellation,
resources, promises, fibers, and dynamic scope. Compare lexical switch
lifetimes with component instances that activate, deactivate, and reactivate
inside a longer-running runtime.

Cover asynchronous teardown, dependency-safe withdrawal, finalizer order,
at-most-once cleanup, partial activation failure, child ownership, and
cancellation races. Identify the smallest missing protocol. Do not propose an
Eio wrapper without an Eta-owned invariant.

Write one cited report under
`.scratch/research/eta-component-runtime/`.
