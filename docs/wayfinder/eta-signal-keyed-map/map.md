# Eta Signal keyed map design map

## Destination

An implementation-ready design for `eta_signal_map`. The design defines its map,
keyed operator, Eta Signal seam, laws, benchmarks, and consumer interface changes.

## Notes

Planning is the deliverable. Implementation is not part of this map.

The structural identity, scope, transaction, and incarnation laws from
[Keyed assoc and stable child identity](../eta-crux-first-principles/issues/04-keyed-assoc-contract.md)
remain inputs. This effort replaces its provisional collection, complexity, and
operator-location decisions.

[Action injection and staged Eta effects](../eta-crux-first-principles/issues/05-action-effect-protocol.md)
and [Dynamic lifetime and work ownership](../eta-crux-first-principles/issues/07-dynamic-lifetime-ownership.md)
own application delivery, cancellation, and lifecycle-hook contracts.

Use `$prototype` for prototype tickets. Use `$research` for research tickets.
Use `$batch-grill-me` and `$domain-modeling` for grilling tickets. Use
`$simple-english` for written artifacts.

Keep prototypes on throwaway branches. Keep durable research under
`.scratch/research/eta-signal-keyed-map/`. Resolve one decision ticket per
session, except research tickets.

The package follows the native `eta_signal` compiler gates. Run repository
verification through the Nix flake.

## Decisions so far

- [Available diffable map sources](issues/01-available-diffable-map-sources.md) — Base is the only complete existing source found, and no small standalone package meets Eta's contract.
- [Current Eta map consumers](issues/02-current-eta-map-consumers.md) — No current package has a material diffable-map use beyond the planned keyed signal layer.
- [Diffable map product boundary](issues/03-diffable-map-product-boundary.md) — Publish an Eta-owned `Eta_signal_map.Map`, use it directly, and limit V1 to one keyed operator.
- [Balancing algorithm evidence](issues/04-balancing-algorithm-evidence.md) — Use a clean-room weight-balanced tree and treat Base as a behavioral oracle.
- [Map kernel prototype](issues/05-map-kernel-prototype.md) — Use a persistent weight-balanced tree with physical-subtree skipping and ordered fallback cursors.
- [Public map API and key discipline](issues/06-public-map-api-and-key-discipline.md) — Publish a small `Map.Make` interface with duplicate rejection and physical-only symmetric diff.
- [Eta Signal extension seam](issues/07-eta-signal-extension-seam.md) — Use a package-private signal kernel and a closed `Eta_signal_map` graph factory.
- [Keyed signal operator contract](issues/08-keyed-signal-operator-contract.md) — Publish `Keyed(Order).mapi` with a directed per-key data cutoff and persistent output-map patching.
- [Executable map laws](issues/09-executable-map-laws.md) — Use claim-specific public and private properties with an independent extensional oracle and physical-identity observations.
- [Keyed operator structural laws](issues/10-keyed-operator-structural-laws.md) — Use 37 claim-specific properties and one independent model trace for identity, cutoff, output, and transaction behavior.
- [Change-proportional benchmark](issues/11-change-proportional-benchmark.md) — Gate shared diff and keyed reconciliation by comparison counts, require affected-child notification, and retain a correct linear fallback for independent maps.

## Not yet specified

None. Each current unknown is precise enough to have a decision ticket.

## Out of scope

- Shipping the implementation as part of this planning effort.
- A complete `Incr_map` operator suite.
- A second map package or a map type in root `eta`.
- Base, Core, Incremental, or `Incr_map` as runtime dependencies.
- Compatibility paths for `Stdlib.Map.S` callers.
- Preserving shared ancestry through serialization or map conversion.
- Retrofitting caches, HTTP registries, metrics, pools, or supervisors.
- A JavaScript-specific signal-map contract.
- OxCaml allocation targets or mode optimization beyond current native gates.
- Eta Crux action delivery, effect cancellation, and lifecycle-hook payloads.
