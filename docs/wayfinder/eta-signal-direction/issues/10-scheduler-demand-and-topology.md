# Scheduler, demand, and topology model

Type: grilling
Status: open
Blocked by: 05, 06, 09

## Question

What scheduler, demand model, and edge representation give Eta Signal
change-proportional propagation and linear wide-node construction?

Decide dirty-frontier ownership, recompute order, necessity reference changes,
timer demand, dynamic-edge updates, static fan-in storage, dynamic edge removal,
and quiescent stabilization. State deterministic complexity contracts for each
operation.

The result must resolve F1, N4, and the engine part of F13. It must preserve the
transaction and invalidation model from
[Transaction and invalidation model](09-transaction-and-invalidation-model.md).
It must distinguish whole-node invalidation from repeated edge detachment while
an owner stays live.
