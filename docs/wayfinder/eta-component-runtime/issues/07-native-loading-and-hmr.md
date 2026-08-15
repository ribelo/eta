# Native loading and HMR

Type: research
Status: resolved
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

## Answer

Native HMR is private loading of immutable, unique `.cmxs` generations,
followed by a separate reconciler transaction that replaces the component
declaration. Replacement withdraws old context effects and creates a fresh
instance. A failed installation restores the old declaration as another fresh
instance. Machine code cannot be unloaded, initializer effects cannot be
rolled back, and a process restart is the code-reclamation boundary. See
[the cited report](../../../../.scratch/research/eta-component-runtime/07-native-loading-and-hmr.md).

### Later refinement

[Module replacement and rollback](17-module-replacement-and-rollback.md)
refines “fresh instance” to “fresh activation generation in the retained
component instance.” The native loading and code-retention conclusions remain
unchanged.

[Integrated design and handoff](22-integrated-design-and-handoff.md) requires a
non-reloadable stable host interface to own configuration types, coeffect
descriptors, and component-family values that cross native generations.
Manifest names remain diagnostic and do not establish type identity.
