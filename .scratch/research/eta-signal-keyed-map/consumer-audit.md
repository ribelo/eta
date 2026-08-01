# Current Eta consumers of a diffable map

Date: 2026-08-01
Repository revision: `dbc470105790bc50d7ed34c72f965431c4657d8a`
Branch: `docs/eta-crux-requirements` at `dbc47010`

## Question

Which current Eta components can benefit from an immutable diffable map?

A material benefit requires repeated comparison of related snapshots, stable
per-key identity, changed-key propagation, or change-proportional work.

## Method

The audit searched `lib/`, `drivers/`, `tools/`, `bench/`, and `test/` for these
collection patterns:

- ordered maps and `Map.Make`
- keyed mutable tables
- old and new snapshot comparison
- reconciliation, demand, and registry code

## Findings

Eta has no production use of `Map.Make`. Mutable hash tables serve caches,
connection registries, spans, streams, and protocol state.

Most of these tables change in place. Their owners do not compare immutable
snapshots. A diffable map gives them no change-proportional benefit.

Eta Signal contains the only current related-snapshot comparison:

- `Eta_signal_graph_algorithms.Demand.diff` compares necessary-node sets.
- `Eta_signal_graph.Core.update_necessary_ids` applies the resulting enter and
  leave counts.

This case uses presence sets over hash tables. The graph rebuilds the complete
next reachability set before it compares sets. A diffable map cannot remove that
dominant rebuild cost by itself.

Dependency-version snapshots use short `(id * version) list` values. These lists
record direct dependencies and do not justify a general map package.

## Excluded components

The following components use keyed mutable state without snapshot comparison:

- `Eta_cache` cache tables
- HTTP connection and stream registries
- OpenTelemetry span and aggregation tables
- pool and supervisor state
- schema and router data

The benchmark tools perform one-time keyed joins. They do not reconcile related
application snapshots.

## Conclusion

No current Eta package needs a public diffable map. Future `eta_signal_map` is
the first material consumer.

The map type belongs in `eta_signal_map`. Root `eta` and existing optional
packages do not gain this collection.
