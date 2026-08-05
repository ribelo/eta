# Dynamic topology and keyed work

Type: prototype
Status:
Blocked by: 01, 06, 07

## Question

How can the same kernel support `bind`, scope invalidation, and keyed membership
with work proportional to the affected topology?

The selected model must preserve child identity, rollback, lifecycle fences,
and dependency ordering without charging static passes for structural machinery.
