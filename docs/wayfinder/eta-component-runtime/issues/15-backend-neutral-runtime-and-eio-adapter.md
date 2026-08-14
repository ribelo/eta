# Backend-neutral runtime and Eio adapter

Type: prototype
Status: open
Blocked by: 03, 04, 06, 11, 12, 13

## Question

Where is the seam between backend-neutral component semantics and the Eio
reference adapter?

Prototype the smallest runtime contract that can schedule lifecycle work,
await dependency-safe teardown, preserve Eta causes, and expose deterministic
test control. Compare direct Eio ownership with composition over current Eta
Runtime and Supervisor interfaces.

Do not expose Eio switches or backend runtime tokens through the public
component interface.
