# Dynamic topology and keyed work

Type: prototype
Status: resolved
Blocked by: 01, 06, 07, 15

## Question

How can the same kernel support `bind`, scope invalidation, and keyed membership
with work proportional to the affected topology?

The selected model must preserve child identity, rollback, lifecycle fences,
and dependency ordering without charging static passes for structural machinery.

The rollback surface grows with topology. A failed pass must also restore edges,
scopes, keyed tables, and output roots, and must not walk more than the affected
topology. It must also define where a removed node leaves the undo journal.

## Answer

Use owner-local shadow capsules for bind and keyed owners.

Each owner keeps committed state, one candidate state, and one intrusive
affected-owner link. A pass verdict publishes all candidate capsules in O(1).

Affected-only cleanup canonicalizes the candidates before callbacks. It also
invalidates old scopes and clears pointer-bearing capsule fields.

Rollback restores roots, scopes, edges, listeners, and demand before the value
journal restores values. Tentative nodes disappear last.

Bind is a one-child stable family. Keyed membership is a multi-child stable
family. Both use the same incarnation, scope, demand, rollback, and cleanup
rules.

The selected prototype allocates 12 words for a dynamic switch. Its keyed rows
allocate 82 to 323 words and pass every workload ceiling.

The largest matched wall-time ratio is 0.772. Static passes bypass the capsule
module and retain the inherited four-word result.

Reject the faster chronological action journal as the private seam. Its
low-level mutation interface makes bind and keyed adapters own the legal edit
sequence.

Reject generic structural cells for the same interface-depth reason. Reject
immutable whole-topology replacement because one edit copies live topology.

The prototypes, measurements, interface comparison, rollback order, and limits
are in
[Dynamic topology and keyed work](../../../../.scratch/research/eta-signal-execution-model/dynamic-topology-and-keyed-work.md).
