# ADR 0004: Lean Eta Signal with a sibling Eta Signal Map

Status: accepted.

## Context

Eta Signal needs a keyed operator for collections that preserve per-key state.
The operator requires a persistent diffable map and a small graph extension
protocol. Most Eta Signal applications do not need either feature.

Eta follows an install-only-what-you-use package policy. Adding keyed
collections to `eta_signal` adds an unrelated collection API to every
signal installation. A public extension API also exposes graph nodes,
scopes, and transaction state that applications must not control.

## Decision

Publish `eta_signal_map` as an optional sibling package. It contains the public
`Eta_signal_map.Map` module and `Eta_signal_map.Make(...).Keyed` operator.

Keep `eta_signal` independent of `eta_signal_map`. Put the required graph
protocol in the package-private `eta_signal_kernel` library. The public
`Eta_signal` interface does not expose this protocol.

Require `eta_signal_map` and `eta_signal` to use the same release version. This
constraint protects the private CMI boundary. Keep the root `eta` package
independent of both optional collection and signal packages.

## Alternatives considered

- Put the map and keyed operator in `eta_signal`. Rejected because most signal
  users do not need keyed collections.
- Publish a general graph extension API. Rejected because it exposes Eta
  Signal transaction and scope invariants.
- Use `Stdlib.Map`, Base, or `Incr_map`. Rejected because the selected contract
  needs persistent ancestry, physical-data diffing, and no external runtime map
  dependency.
- Publish the private kernel as a third opam package. Rejected because it is an
  implementation protocol, not an application API.

## Consequences

Applications install `eta_signal_map` only when they need keyed collections.
The package can evolve its public map and keyed operator without widening
`eta_signal`.

The private CMI creates a strict same-version dependency. The release process
must build and test both packages together. A future graph consumer depends on
`eta_signal_map`, not on the private kernel.
