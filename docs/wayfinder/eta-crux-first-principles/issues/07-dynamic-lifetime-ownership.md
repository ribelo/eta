# Dynamic lifetime and work ownership

Type: grilling
Status: claimed
Blocked by: 03, 05

## Question

What does activation, deactivation, and disposal mean for a dynamically selected
or keyed child computation?

Decide:

- when local state is created and when it becomes observable.
- whether temporary inactivity preserves or disposes state.
- which resources, staged effects, running effects, timers, and external sources
  belong to the child scope.
- cancellation and finalizer order on branch replacement or key removal.
- the behavior of queued actions and captured injectors after disposal.
- whether work can detach from its declaring computation.
- how a caller models work that must outlive the view or child that requested it.
- which cleanup failures remain visible after another failure.

Use Eta structured concurrency and GC deliberately. GC can reclaim unreachable
descriptions, but correctness and timely cleanup must not depend on finalizer
timing.
