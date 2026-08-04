# Incremental engine reference

Type: research
Status: open
Blocked by: none

## Question

Which Jane Street Incremental mechanisms are useful evidence for Eta Signal's
transaction, scheduling, demand, topology, invalidation, and observer-order
decisions?

Read primary Incremental and Incr_map source. Trace dirty propagation, height or
topological maintenance, necessity transitions, edge representation, bind and
scope invalidation, keyed-node removal, commit boundaries, exception regions,
and observer delivery order.

State the invariant each mechanism owns. Separate semantic requirements from
representation choices. Identify mechanisms that Eta must not copy because its
effect or lifecycle contract differs. Save the report under
`.scratch/research/eta-signal-direction/`.
