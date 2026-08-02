# Diffable map product boundary

Type: grilling
Status: resolved
Blocked by: 01, 02

## Question

What product boundary, source policy, and performance contract govern the
diffable map and the V1 keyed operator?

## Answer

Applications use the immutable ordered map directly. The public module is
`Eta_signal_map.Map` inside the `eta_signal_map` package.

Eta writes its map implementation from the cited weight-balanced-tree papers.
Eta does not copy the Base implementation. Eta rewrites the relevant Base test
scenarios in Alcotest or QCheck and cites the reviewed Base revision.

Diff remains correct for any two maps with the same key order. The
change-proportional guarantee applies only to snapshots with shared persistent
ancestry. Independently rebuilt maps can require linear work.

The keyed operator returns the same map type. It updates the prior output map so
downstream keyed operations retain shared ancestry.

V1 publishes only the per-key signal operator required by Eta Crux `Assoc`. It
does not publish a broader incremental collection suite.

A prototype decides the smallest practical `Map.S` subset. The prototype uses
application-shaped construction and update examples.

The ported test scope covers these areas:

- tree and map invariants
- symmetric-diff semantics
- forward and reverse reconstruction properties
- asymptotic comparison growth under shared ancestry

Exact Base comparison counts and unrelated Base APIs are not compatibility
targets.
