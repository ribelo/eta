# Typed observation plan for host delivery

Type: prototype
Status: claimed
Blocked by: 03, 04, 06, 07

## Question

Can an adapter attach a typed observation plan to opaque Eta Crux computations
and receive granular stabilized changes without changing the canonical typed
root result?

Prototype snapshot-only reconciliation and the smallest credible observation
plan. The observation plan must not expose `eta_signal`, public output paths,
type witnesses, `Obj`, or host callbacks during pure stabilization.

Exercise:

- one scalar projection.
- one change in a 10,000-row keyed collection.
- an unrelated projection that must not run.
- dynamic removal that disposes its observation exactly once.
- a stale injector that must not act after removal.
- deterministic delivery after the pure snapshot commits.

Compare API depth, allocations, recomputation, host mutation count, lifecycle
complexity, and testability. If the plan is not a small deep interface, keep
root snapshots and adapter-owned diffing until measured pressure justifies more.
Link all prototype assets from the answer.
