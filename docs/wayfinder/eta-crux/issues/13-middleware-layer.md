# Middleware layer for capability messages

Type: grilling
Status: open
Blocked by: 04

## Question

Crux has a layer that handles effects inside the core boundary but outside the application.
eta_crux has application-owned commands and shell-owned capability messages, with nothing
between them.

Some capabilities are neither application logic nor foreign-shell work: filesystem access, a
clock, a key-value store, an HTTP client. Today each must be written into every application's
commands or pushed out to the shell. A middleware layer is also the natural home for
cross-cutting concerns that must not become application code: capability-message logging,
redaction, a recording layer for tests, or handling a subset of capability messages in OCaml
while forwarding the rest.

Decide:

- Whether a middleware layer may handle a capability message inside the core and resolve it
  as an inbound action without reaching the adapter.
- That declining a message forwards it unchanged toward the adapter.
- That installing middleware preserves action admission, tick ordering and crash-boundary
  semantics.
- That middleware is optional, and that an application without it behaves exactly as
  specified.

Blocked by ticket 04 because a middleware layer that resolves a capability message needs
whatever resolution mechanism that ticket settles.
