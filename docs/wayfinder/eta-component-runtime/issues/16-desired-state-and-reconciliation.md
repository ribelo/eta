# Desired state and reconciliation

Type: prototype
Status: open
Blocked by: 02, 12, 13, 14

## Question

What typed desired-state tree and reconciliation algorithm can create, remove,
move, disable, reconfigure, isolate, and intercept component instances?

Prototype stable entry identity, keyed child reconciliation, nested groups, and
concurrent module preparation. Define the authority split between an entry, a
component instance, and application-owned configuration.

The answer must make final quiescent state depend on final desired state, not
on reconciliation order.
