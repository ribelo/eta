# Typed coeffect representations

Type: research
Status: open
Blocked by:

## Question

Which OCaml and OxCaml representations can provide statically typed coeffect
keys and practical component requirement and provision declarations?

Compare generative typed keys, GADTs, extensible variants, first-class modules,
objects and object rows, polymorphic variants, functors, existential packages,
and type witnesses. Include dynamic lookup, heterogeneous storage, separate
compilation, key identity, error locality, value restriction, and inference.

Treat the prior no-`R` evidence as a binding constraint. A representation must
not add an environment parameter to `Effect.t`. Check portability across OxCaml
domain boundaries and identify which claims require compiler probes.

Write one cited report under
`.scratch/research/eta-component-runtime/`.
