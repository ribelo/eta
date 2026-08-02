# Deterministic advancement transaction

Type: grilling
Status: claimed
Blocked by: 05

## Question

What does one deterministic advancement do, in what order, and where is its
commit boundary?

Decide:

- whether an advancement processes one action or a bounded available batch.
- when pending input changes enter the graph.
- model transition and commit order across independent state machines.
- `eta_signal` stabilization and rollback behavior.
- dynamic activation and deactivation order.
- output publication and adapter notification order.
- when staged effects start.
- how actions injected during any phase are deferred.
- wake conditions for hosted execution, timers, shutdown, and external sources.
- the exact result returned by explicit advancement.

The hosted loop and all test drivers must use this same transaction. The answer
must make partial state and reentrant advancement impossible or explicitly
typed as an error.
