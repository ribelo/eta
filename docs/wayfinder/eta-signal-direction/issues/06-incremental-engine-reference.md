# Incremental engine reference

Type: research
Status: resolved
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

## Answer

Jane Street Incremental provides useful semantic requirements:

- Compute only necessary stale nodes.
- Propagate changed values to necessary parents.
- Recompute children before consumers.
- Update demand edges as necessity changes.
- Invalidate obsolete bind scopes under the default reference configuration.
- Remove and invalidate removed keyed nodes.
- Keep every successfully stabilized necessary graph acyclic.
- Deliver at most one valid observer update per handler after recomputation.

Its height heap, packed arrays, intrusive scope lists, and mutable keyed
accumulators are representation choices. LIFO callback stacks, synchronous
`Expert` callbacks, finalizer demand, and permanent exception poisoning are
lifecycle choices. Eta must not copy them as contracts. The desired Eta model
needs typed effect failures, cancellation, explicit scope ownership, and a
transaction boundary. [Atomic phase entry](02-atomic-phase-entry.md) and [keyed
bind invalidation](03-keyed-bind-invalidation.md) prove that the current
implementation does not enforce that boundary universally. [Transaction and
invalidation model](09-transaction-and-invalidation-model.md) owns the final
model.

The primary `incremental` source is pinned at commit
`2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6`. The primary `incr_map` source is
pinned at commit `21c6bc602c75d57242b4c3e945da597f82c6280f`. The named packed
audit file is absent, but the pinned `incr_map` checkout supplies the required
keyed evidence. The independent review records different Eta commit labels.
Ticket 01 proved that the relevant Signal trees are identical at those commits.
No requested source fact remains blocked.

Research report:

- [Incremental engine reference](../../../../.scratch/research/eta-signal-direction/incremental-engine-reference.md)

### Census rows resolved here

- External keyed engine evidence: `F02-004` and `F02-005`.
- Cycle behavior: `S17-001`, `S17-002`, and `S17-003`. Incremental checks an
  active necessary-parent edge after insertion. Necessary Expert dependencies
  use the same path. The check does not provide atomic rejection.
