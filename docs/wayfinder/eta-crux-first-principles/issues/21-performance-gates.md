# V1 performance gates

Type: prototype
Status: open
Blocked by: 09, 10, 12, 15, 18

## Question

Which performance budgets and benchmark scenarios can guard the V1 design
without encoding accidental implementation details?

Prototype and measure at least:

- one action and one complete advancement.
- unchanged incremental recomputation.
- one changed child in a large keyed map.
- committed root-output delivery and adapter reconciliation.
- lifecycle removal with overlapping cleanup.
- identity and serialized driver overhead.
- test instrumentation when disabled.
- bounded memory for ingress, requests, exports, and serialized registries.

Select reproducible Nix benchmark commands, input sizes, reported statistics,
and regression thresholds. Keep benchmarks outside `dune runtest`. Do not claim
change-proportional behavior where the selected collection contract provides
only a linear scan.
