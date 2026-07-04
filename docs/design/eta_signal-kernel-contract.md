# Eta_signal Kernel Contract

Source plan: `/home/ribelo/projects/ribelo/ocaml/Eta/docs/gpt-pro/6a48b50c-6be4-83eb-a795-faf8fdda37af.md`.

This document freezes the public behavior that the `eta_signal` strangler
redesign must preserve while the implementation moves from the current
single-file kernel toward private internal modules such as `Transaction`,
`Stabilization`, `Kernel`, `Scope`, `Bind`, `Timer`, and `Stream_bridge`.

The public `Eta_signal.Make` interface remains the contract boundary. Internal
files may move, split, or disappear, but the behavior below must remain true
unless the public interface is deliberately changed and its tests are updated.

## Stabilization Boundary

`Var.set` and `Var.update_effect` update source variables and mark graph work
pending. They do not recompute derived signals, publish observer values, or run
observer callbacks by themselves.

`stabilize` is the only propagation boundary. A stabilization performs pure
graph recomputation first, then publishes a consistent pure snapshot, then
delivers observer effects.

Pure recomputation happens before observer effects. Observer callbacks must see
an already-published snapshot for the stabilization that invoked them.

Pure snapshot publication is atomic. If pure graph recomputation, cutoff
comparison, source equality, scope validation, cycle detection, or a similar
pre-commit graph operation fails, the previous stabilized snapshot remains
observable and pending source updates remain retryable.

Observer callbacks are not part of the pure transaction. Once the pure snapshot
has committed, callback typed failures, callback defects, interruption, timer
lifecycle cleanup, and disposal-hook failures do not roll back the committed
snapshot.

Mutations performed from observer callbacks are accepted as pending source
updates. They are not visible to the observer-phase snapshot that is currently
being delivered, and they publish only after a later explicit stabilization.

## Demand Boundary

Observers are the demand roots for the graph. Registering an observer makes the
observed signal and its committed dependencies necessary. Disposing the last
observer removes that demand.

Unobserved derived nodes do not recompute merely because their sources were set.
Reading an observer returns the last stabilized observer value; it does not force
derived recomputation.

Timers are demand-owned adapters. Constructing a timer-backed signal does not
start timer work. Timer work starts only while the timer signal is necessary,
stops or becomes inert when unnecessary, and never calls `stabilize` itself.

Timer-backed sources are refreshed through the same explicit stabilization
boundary as ordinary sources. Timer wakeups may enqueue source updates, but
observers see those changes only after `stabilize`.

Stream bridges are observers plus queues. They are not kernel nodes and do not
create a stream-to-signal path.

## Error Boundary

Graph contract violations are typed graph failures when an Eta effect error
channel exists. Synchronous graph construction APIs raise `Graph_error` for the
same graph failures.

Cycle detection, reentrant stabilization, reentrant source updates, invalid
dynamic scopes, ambiguous dynamic scopes, runtime mismatches, and counter
overflows are graph failures.

User callback typed failures surface through `stabilize` as
`Observer_error`. Ordinary exceptions raised while constructing a callback
effect, defects raised by a callback effect, pure graph callback exceptions, and
cutoff/equality exceptions are defects, not typed observer failures.

Observer typed failures occur after pure snapshot commit. The observer current
value remains the committed value, and the failed delivery remains pending until
a later stabilization can acknowledge, coalesce, skip, or redeliver it.

## Dynamic Scope Boundary

`bind` dynamically selects a signal from the stabilized source value. The
selector runs during pure recomputation and must be pure and total.

When a bind switches branches, old committed inner dependencies are detached
only as part of the successful snapshot switch. A failed switch preserves the
previous snapshot and previous active dependency graph.

Nodes created inside an inactive branch are invalidated when that branch is
replaced. Captured inactive-branch nodes cannot become valid demand roots.

Cycle detection remains graph-global across static and dynamic dependencies.

## Stream Bridge Boundary

`Stream.observe` creates an observer lifecycle handle and a bounded update
queue. Publication to that queue happens during observer delivery after
stabilization commits.

Bridge publication is nonblocking. When the queue is full, the newest update is
dropped, the drop is acknowledged once, and stabilization continues.

The optional `on_drop` hook is best-effort diagnostics. If it raises, the drop
is still acknowledged, the hook is not retried, and graph progress continues.

Disposing the returned observer closes the queue after buffered updates drain.
Stopping stream consumption early does not dispose the observer.

## Redesign Constraints

The redesign must not introduce a public graph value, public scope value, global
graph, raw derived-signal read, public batch primitive, stream-to-signal bridge,
automatic stabilization, or timer scheduler owned by `eta_signal`.

The final implementation should move policy behind private deep modules, but
the public facade must continue to behave as a single graph instance produced by
each application of `Eta_signal.Make`.
