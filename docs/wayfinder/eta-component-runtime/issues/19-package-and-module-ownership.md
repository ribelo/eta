# Package and module ownership

Type: grilling
Status: open
Blocked by: 15, 16, 17, 18

## Question

Which public packages and private modules own the selected component runtime,
desired-state loader, HMR adapters, and Eio integration?

Start from `eta_component` plus a separate loader package. Apply Eta's
install-only-what-you-use policy. Keep serialization, file watching, native
loading, Eio, and test dependencies in their owning optional packages.

Define public top-level module names and reject dotted public library names.
