# Exported endpoint and handle contract

Type: prototype
Status: open
Blocked by: 05, 07, 11

## Question

What is the exact transport-neutral contract for exposing a typed local
endpoint to a shell?

Prototype one local identity transport and one serialized loopback transport.
Decide:

- the public shape of `Exported_endpoint.t` and codec attachment.
- whether export is a computation node or an adapter operation.
- stable export identity across recomputation.
- activation, revocation, tombstones, and same-structure re-entry.
- session-scoped generational remote handles.
- the core-side registry and its existential codec packaging.
- how `Endpoint.contramap` narrows the remotely accepted payload.
- errors for unknown, stale, malformed, revoked, full, and closed invocations.
- whether local transport performs any remote-handle lookup or encoding.

The shell must not receive an internal graph path, machine identifier, complete
action protocol, closure, or type witness. Local and serialized invocation must
enqueue the same typed message.

Core endpoint admission returns only `Ingress_closed`. A nonblocking exported
invocation also needs a capacity result. This ticket must keep transport and
handle failures distinct from both results.
