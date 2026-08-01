# Package and documentation boundary

Type: grilling
Blocked by: 09, 10, 11, 12, 13

## Question

What final package, library, test, benchmark, requirement, and ADR layout makes
the design implementation-ready?

Fix the Dune and opam dependency graph for `eta_signal`, `eta_signal_map`, Eta
Crux, and test support. Root `eta` must not gain the map or keyed operator.

Identify the canonical public `.mli` files, law suites, benchmark targets, Nix
gates, and executable-law registry rows.

Decide which provisional statements in these sources are replaced:

- [Keyed assoc and stable child identity](../../eta-crux-first-principles/issues/04-keyed-assoc-contract.md)
- [Engine strategy](../../../requirements/eta-crux/engine-strategy.md)
- [eta_signal_map and minimal eta_signal hook contract](../../eta-crux/issues/16-eta-signal-map-contract.md)

Name any ADR that the final tradeoffs justify. Do not write implementation
requirements for another package inside the Eta Crux requirement bundle.

Record the two external Eta Crux decisions named by the map as consumer
prerequisites. Do not resolve them in this effort.

The answer must leave no package or documentation ownership decision for
implementation.
