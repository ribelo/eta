# Eta execution-cost decomposition

Type: prototype
Status: resolved

## Question

Which measured costs belong to raw graph work, Eta Effect interpretation, the
graph lane, Eio scheduling, timer protocols, and observer delivery?

Build throwaway probes around the same graph operation. Measure each added
adapter independently so that the effect tax does not appear as graph cost.

## Answer

The current raw planner allocates `729 + (68 * depth)` words for one changed
scalar operation. The complete Eio and no-op observer path adds 4,576 fixed
words.

Eta Effect adds 10 words. One fused lane acquisition adds 169 words. The split
public protocol adds 1,083 words. Eio adds 1,174 words without a scheduler
switch. Observer demand and delivery add 2,140 words.

One explicit Eio-backed yield adds 53 words. The ordinary public operation does
not yield or wait.

One active, non-firing timer adds `2,315 + (6 * depth)` words. It also activates
a triangular dirty-journal search on the changed chain.

The probe, measurements, source attribution, and limits are in
[Eta execution-cost decomposition](../../../../.scratch/research/eta-signal-execution-model/eta-execution-cost-decomposition.md).
