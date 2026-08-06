# Value-propagation kernel prototype

Type: prototype
Status: resolved
Blocked by: 02, 04, 05

## Question

Can a raw Eta kernel match Incremental for static value propagation while it
preserves Signal cutoffs, demand, ordering, and explicit stabilization?

Prototype in-place state, staleness tracking, and affected-parent scheduling.
Measure raw depth, fan-in, cutoff, and observer-free paths before adding an Eta
adapter.

## Answer

Yes. A synchronous direct-propagation kernel passes the applicable behavior,
affected-work, allocation, and wall-time gates.

The kernel allocates 4 words for changed depths 1, 10, and 100. Its largest
paired wall-time ratio against Incremental is 0.614.

Use retained values, pass stamps, affected-parent scheduling, height buckets,
and a direct unary-parent path.

Reject strict immutable prospective snapshots. Their allocation increases from
9 words at depth 1 to 108 words at depth 100.

The prototype, complete measurements, limits, and next constraints are in
[Value-propagation kernel prototype](../../../../.scratch/research/eta-signal-execution-model/value-propagation-kernel.md).
