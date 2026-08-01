# Keyed assoc and stable child identity

Type: prototype
Status: claimed
Blocked by: 03

## Question

What exact public and engine contract gives `assoc` stable per-key computation
identity, state, and lifecycle without turning the core into a collection
framework?

The decision must cover:

- the input collection and comparator or key-module discipline.
- child construction for a newly present key.
- updates to data for an existing key without rebuilding its child.
- child output collection and deterministic key order.
- removal, scope disposal, stale injection, and later re-entry of the same key.
- duplicate or invalid key states, if the chosen collection can represent them.
- the narrow `eta_signal` capability needed to implement the contract.

Prototype the public type and the private engine seam. Show a keyed child with
local state across data updates, removal, and re-entry. Do not expose a broad
`Expert` or public scope API only to make `assoc` possible.
