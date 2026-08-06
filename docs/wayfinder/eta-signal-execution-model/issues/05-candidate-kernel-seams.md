# Candidate kernel seams

Type: grilling
Status: resolved
Blocked by: 01, 03, 04

## Question

Which radically different kernel interfaces and effect seams deserve
prototypes?

Use Design It Twice. Include a pure kernel that returns a declarative plan, a
pure propagation kernel with an Effect adapter, and a synchronous graph with
effects only at external edges. Compare depth, locality, and seam placement.

## Answer

Use a synchronous direct-propagation module as the primary hypothesis. It gives
the best depth, locality, and static allocation outlook.

Run a short immutable-plan falsification probe before rejecting declarative
snapshots. Stop when allocation reaches 100 words, grows with depth, or commit
requires closures.

After the raw kernel passes, compare private driver claims with explicit
post-commit edge cursors. Reject injected clock, serialization, delivery, and
lifecycle ports at the raw seam because they export Signal protocol.

The four designs, interfaces, comparison, dependency placement, and prototype
sequence are in
[Candidate kernel seams](../../../../.scratch/research/eta-signal-execution-model/candidate-kernel-seams.md).
