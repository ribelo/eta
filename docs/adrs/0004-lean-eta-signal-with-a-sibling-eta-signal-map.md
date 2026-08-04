# ADR 0004: Lean Eta Signal with a sibling Eta Signal Map

Status: accepted.

## Context

Eta Signal needs a keyed operator for collections that preserve per-key state.
The operator requires a persistent diffable map and stable-family semantics.
Most Eta Signal applications do not need the map.

Eta follows an install-only-what-you-use package policy. Adding keyed
collections to `eta_signal` adds an unrelated collection API to every
signal installation. A broad extension API also exposes engine authority that
applications and library packages must not control.

## Decision

Publish `eta_signal_map` as an optional sibling package. It contains the public
`Eta_signal_map.Map` module and a keyed adapter for an existing Signal graph.

Keep `eta_signal` independent of `eta_signal_map`. Make `Eta_signal.Make` the
sole graph factory. Each graph exposes one opaque, graph-branded package
endpoint.

The endpoint accepts one sealed stable-family plan form. It exposes no graph,
node, edge, scope, phase, transaction, scheduler, demand, cleanup, or mutation
handle.

`Eta_signal_map.Make` accepts that endpoint. It never creates another graph.
Its operators return the existing graph's signal type.

Require `eta_signal_map` and `eta_signal` to use the same release version. This
constraint lets the protocol and first-party consumers change together. Keep
the root `eta` package independent of both optional collection and signal
packages.

## Alternatives considered

- Put the map and keyed operator in `eta_signal`. Rejected because most signal
  users do not need keyed collections.
- Publish a general graph extension API. Rejected because it exposes Eta Signal
  transaction, topology, demand, scheduling, and scope invariants.
- Keep keyed nodes embedded behind a replacement Signal Map graph factory.
  Rejected because two optional structural packages cannot share one graph.
- Use `Stdlib.Map`, Base, or `Incr_map`. Rejected because the selected contract
  needs persistent ancestry, physical-data diffing, and no external runtime map
  dependency.
- Publish the private kernel as a third opam package. Rejected because the
  kernel is an implementation, not a package interface.

## Consequences

Applications install `eta_signal_map` only when they need keyed collections.
The package can evolve its public map and keyed operator without widening
`eta_signal`.

Applications create one graph. Multiple stable-family packages can adapt the
same endpoint without receiving engine authority.

The stable-family protocol creates a strict same-version dependency. The release
process builds and tests first-party protocol consumers together.

External packages can implement stable keyed collections. Packages that need
arbitrary dependencies, scheduling, invalidation, or commit hooks cannot use
this seam.
