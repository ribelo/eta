# Domain-Isolated Blocking Pool Safety Note

The domain-isolated pool is an escape hatch for legacy C bindings that hold the
OCaml runtime lock while blocking or burning CPU. It is not the default blocking
pool and not a substitute for `Eta.island`.

Safety contract:

- The API name should be deliberately explicit, e.g.
  `Blocking.Pool.create_domain_isolated`.
- Inputs and outputs must be portable/shareable enough to cross a domain
  boundary. Eio handles must not cross.
- The worker must be one-shot: input in, result or exception out.
- It is only for unsafe or uncooperative legacy bindings proven to break Eio
  heartbeat under systhreads.
- CPU work that can be made portable should use `Eta.island`, not this escape
  hatch.
