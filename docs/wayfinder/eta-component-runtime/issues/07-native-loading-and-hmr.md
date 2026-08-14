# Native loading and HMR

Type: research
Status: open
Blocked by:

## Question

What can hot module replacement mean for native OxCaml and Eta without a
managed module cache?

Use primary OCaml, OxCaml, Dune, and platform sources. Cover `Dynlink`, native
plugin loading, symbol and type identity, code unloading limits, file watching,
recompilation, cache invalidation, rollback after load failure, and replacement
of a component value without unloading machine code.

Separate the portable semantic contract from adapter-specific loading
mechanisms. Identify a feasible minimum HMR contract and any requirements that
native OCaml cannot satisfy.

Write one cited report under
`.scratch/research/eta-component-runtime/`.
