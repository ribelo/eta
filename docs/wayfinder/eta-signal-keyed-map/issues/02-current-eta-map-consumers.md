# Current Eta map consumers

Type: research
Status: resolved
Blocked by: none

## Question

Which current Eta components can materially benefit from a diffable map?

Count only repeated related-snapshot comparison, changed-key propagation,
stable per-key identity, or change-proportional work.

## Answer

No current Eta package provides a material consumer.

Eta Signal compares old and new necessary-node sets. However, it first rebuilds
the complete reachability set. A diffable map cannot remove that dominant work
without a separate graph algorithm change.

Other keyed components use mutable registries or one-time accumulation. They do
not compare persistent snapshots.

Future `eta_signal_map` is the first material consumer. The collection does not
belong in root `eta` or another current optional package.

Research report:

- [Consumer audit](../../../../.scratch/research/eta-signal-keyed-map/consumer-audit.md)
