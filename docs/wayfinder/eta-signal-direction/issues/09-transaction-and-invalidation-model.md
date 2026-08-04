# Transaction and invalidation model

Type: grilling
Status: open
Blocked by: 01, 02, 03, 06

## Question

What transaction and invalidation model gives Eta Signal atomic phase entry, one
closed invalidation frontier, and an explicit non-failing commit boundary?

Decide the phase model, transaction identity, planning result, staged-operation
partition, provisional-scope cleanup, rollback authority, commit authority, and
post-commit failure behavior. Cover ordinary bind switches, keyed removals,
nested combinations, cycle failures, callback defects, and independent graphs
on separate domains.

The result must assign each invariant to one deep module. It must resolve N1,
N2, and N5 rather than add checks around the current order.
