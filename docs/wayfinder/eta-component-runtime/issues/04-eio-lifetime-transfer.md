# Eio lifetime transfer

Type: research
Status: resolved
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

## Answer

[Research report](../../../../.scratch/research/eta-component-runtime/04-eio-lifetime-transfer.md)

Eio proves the lexical resource and child lifetime of one activation. A
backend-neutral component context must add serialized generations, staged
publication, admission fencing, and dependency-safe withdrawal.
