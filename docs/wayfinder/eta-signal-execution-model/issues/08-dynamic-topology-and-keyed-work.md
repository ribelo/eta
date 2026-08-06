# Dynamic topology and keyed work

Type: prototype
Status:
Blocked by: 01, 06, 07, 15

## Question

How can the same kernel support `bind`, scope invalidation, and keyed membership
with work proportional to the affected topology?

The selected model must preserve child identity, rollback, lifecycle fences,
and dependency ordering without charging static passes for structural machinery.

The rollback surface grows with topology. A failed pass must also restore edges,
scopes, keyed tables, and output roots, and must not walk more than the affected
topology. It must also define where a removed node leaves the undo journal.
