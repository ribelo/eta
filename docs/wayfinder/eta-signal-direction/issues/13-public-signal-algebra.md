# Public Eta Signal algebra

Type: grilling
Status: resolved
Blocked by: 07, 08, 10, 11, 12

## Question

What exact public Eta Signal algebra is deep, regular, and coherently complete?

Examine variables, signals, stabilization, static combinators, dynamic
composition, cutoffs, observers, lifecycle, time, streams, folds,
introspection, and the Eta Signal Map relationship. Separate primitive
operations from aliases and optional subsystems.

Decide the accepted parts of F4, F8, F9, F11, and F12. Feature parity is not a
goal. A missing operation can earn inclusion when it completes a coherent
algebra, removes an interface irregularity, or gives external consumers useful
leverage. Internal repository use is not a prerequisite.

## Answer

**Status: resolved.**

Eta Signal keeps a small scalar algebra, engine-owned time and diagnostics, and
one optional stream bridge package.

The public algebra gains immutable named cutoffs and one balanced associative
reduction. It gains no parity batch, mutable cutoff, bind rescoping, raw signal
read, or node-level lifecycle API.

## Package layout

The package graph is:

```text
eta_signal -> eta, eta_observability
eta_signal_stream -> eta_signal (= same release), eta_stream
eta_signal_map -> eta_signal (= same release)
```

`eta_signal` no longer depends on `eta_stream`. Ordinary Signal installation no
longer installs Eio or Cstruct through that bridge.

Time and diagnostics stay in `eta_signal`. They add no provider dependency, and
the engine owns their demand and snapshot protocols.

`eta_signal_stream` publishes `Eta_signal_stream`. Its functor adapts one graph's
narrow `Signal.For_stream` endpoint.

The stream package uses one sealed observer-delivery capability. It receives no
graph, node, scope, transaction, raw delivery cursor, or mutation handle.

## Cutoff

`Eta_signal.Cutoff` is outside the graph functor:

```ocaml
module Cutoff : sig
  type 'a t

  val always : 'a t
  val never : 'a t
  val phys_equal : 'a t
  val of_equal : ('a -> 'a -> bool) -> 'a t
  val of_compare : ('a -> 'a -> int) -> 'a t
end
```

A cutoff receives the published value first and the candidate second. A true
result suppresses the candidate.

`always` suppresses every candidate. `never` suppresses none. `phys_equal` uses
physical equality.

`of_equal equal` uses `equal published candidate`. `of_compare compare`
suppresses when `compare published candidate = 0`.

Physical equality is the default for every optional cutoff.

Replace public `?equal` with `?cutoff` where later candidates can occur. Delete
the old arguments and update all callers directly.

`const` loses its equality argument because it has no later candidate.

A producer cutoff controls cached publication and downstream propagation. An
observer cutoff controls changed-event delivery only.

An observer's current value advances when its delivery cutoff suppresses an
event. A cutoff never suppresses `Initialized`.

Cutoffs are fixed at construction. Eta exposes no `get_cutoff` or `set_cutoff`.
The immediate-versus-future reevaluation question therefore does not enter V1.

The stable-family plan and `Keyed.mapi` use `?data_cutoff:'a Cutoff.t`. They no
longer accept a raw equality function.

## Scalar graph algebra

The exact scalar constructors are:

```ocaml
val const : 'a -> 'a signal

val map :
  ?cutoff:'b Cutoff.t ->
  ('a -> 'b) ->
  'a signal ->
  'b signal

val map2 :
  ?cutoff:'c Cutoff.t ->
  ('a -> 'b -> 'c) ->
  'a signal ->
  'b signal ->
  'c signal

(* The same direct shape continues through map9. *)

val all :
  ?cutoff:'a list Cutoff.t ->
  'a signal list ->
  'a list signal

val bind :
  ?cutoff:'b Cutoff.t ->
  f:('a -> 'b signal) ->
  'a signal ->
  'b signal
```

Configuration labels come first. Pure functions precede their signal arguments.
Mutable targets remain first in mutable operations.

`bind` changes from `bind signal f` to `bind ~f signal`. This makes `map` and
`bind` pipe in the same direction.

`map2` through `map9` remain direct static-node constructors. They avoid the
extra tuple nodes that derived heterogeneous arities require.

Delete `both`. It duplicates `map2`, creates a fresh pair, and lacks a cutoff.

Do not add `join`, `if_`, infix operators, `bind2` through `bind4`, `map10`,
`freeze`, snapshots, memoization, or raw node handlers.

Scheduler-sensitive convenience nodes need a separate external task. No current
candidate has one.

A cheap alias can enter when it improves repeated code without new semantics.
No current alias meets that test.

API absence is not a defect and receives no negative omission test.

Repeated `Var.set` operations before `stabilize` already form the public update
batch. Eta adds no separate batch handle.

Pure graph callbacks must be total and free of side effects. A callback defect
before commit rolls back the attempt and leaves source work retryable.

## Variables and reads

The exact variable surface is:

```ocaml
module Var : sig
  type 'a t = 'a var

  val create : ?cutoff:'a Cutoff.t -> 'a -> 'a t
  val value : 'a t -> 'a
  val watch : 'a t -> 'a signal
  val set : 'a t -> 'a -> (unit, [> `Reentrant_update ]) Eta.Effect.t

  val update_effect :
    'a t ->
    ('a -> ('a, 'err) Eta.Effect.t) ->
    ('a, [> `Reentrant_update ] as 'err) Eta.Effect.t
end
```

Eta exposes exactly two read meanings:

- `Var.value` reads the latest accepted source value.
  This includes an unstabilized set.
- `Observer.read` reads the last committed observed value and never recomputes.

Raw signals remain unreadable. Eta adds no `node_value`, `is_valid`,
`is_necessary`, or second latest-value alias.

Delete public `Observer.unsafe_read_exn`. Repository-private test support can
inspect state through typed probes.

## Graph errors

`graph_error` and `Graph_error` move outside the graph functor:

```ocaml
type graph_error =
  [ `Ambiguous_scope
  | `Counter_overflow of string
  | `Cycle
  | `Domain_mismatch
  | `Invalid_scope
  | `Reentrant_stabilization
  | `Runtime_mismatch
  | `Reentrant_update ]

exception Graph_error of graph_error
```

Every graph result aliases this type. Package adapters therefore preserve graph
failures without a private kernel type.

Synchronous wrong-domain calls raise `Graph_error Domain_mismatch`. They no
longer raise `Invalid_argument`.

## Balanced reduction

Add one associative static reduction:

```ocaml
val reduce_balanced :
  ?cutoff:'a Cutoff.t ->
  identity:'a ->
  combine:('a -> 'a -> 'a) ->
  'a signal array ->
  'a signal
```

`combine` is pure, total, and associative at the observation boundary.
`identity` is its left and right identity at that boundary.

Eta copies the input array during construction. Later caller mutation cannot
change graph topology or reduction order.

Reduction preserves array order. Empty input publishes `identity`.

Initial evaluation uses O(n) combination work. One changed child uses
O(log(n + 1)) combination work.

Tickets 09 and 10 settled the F1 and N4 prerequisites. Reduction implementation
follows their transaction, scheduler, and edge changes.

The final cutoff applies only to aggregate publication. Internal tree cells do
not suppress intermediate candidates.

A `combine` defect follows pre-commit rollback and retry rules.

Eta adds no update-aware delta fold. An O(1) replacement fold needs an explicit
inverse or replacement algebra and a concrete consumer contract.

Dynamic membership reduction belongs to a collection package, not the scalar
array algebra.

## Dynamic composition

`bind` always invalidates the previous branch scope before it attaches the new
branch. Eta exposes no rescope mode.

Rescoping changes capture, keyed-child, timer, observer, rollback, and
invalidation semantics. It is not a convenience flag.

A future rescope design needs a branch-flapping workload, benchmark evidence,
and a separate complete lifecycle contract.

Tickets 09 through 12 settle the old prerequisites. Rejection closes the
near-term implementation route.

## Observers

Value updates remain:

```ocaml
type 'a update =
  | Initialized of 'a
  | Changed of { old_value : 'a; new_value : 'a }
```

An active observer keeps its root necessary. `Unnecessary` has no valid meaning
in this update type.

Disposal and invalid scope are lifecycle finishes, not value updates. No new
value callback starts after finish.

The observer surface is:

```ocaml
type observer_finish = [ `Disposed | `Invalid_scope ]

module Observer : sig
  type 'a t = 'a observer

  val observe :
    ?cutoff:'a Cutoff.t ->
    ?on_finish:(observer_finish -> unit) ->
    ?on_update:('a update -> (unit, observer_error) Eta.Effect.t) ->
    'a signal ->
    ('a t, graph_error) Eta.Effect.t

  val read : 'a t -> ('a, observer_read_error) Eta.Effect.t
  val dispose : 'a t -> (unit, graph_error) Eta.Effect.t
end
```

`on_update` is optional. An observer without it still owns demand and advances
its committed current value.

`on_finish` runs exactly once after the observer enters its terminal state.
Active disposal reports `Disposed`. Scope invalidation reports `Invalid_scope`.

Disposal after a finish emits nothing. Finish clears pending update delivery
before the hook runs.

A callback that started before finish can complete. Finish prevents its
acknowledgement and retry.

A finish hook is synchronous and must be total. An exception is an Eta defect.
It never becomes `observer_error` and never restores observer activity.

Ticket 11 still owns topological update order, fail-fast delivery, coalescing,
retry, acknowledgement, and disposal races.

## Stream bridge

Each graph result exposes a narrow `For_stream` module. It contains type aliases
and only the observer operations required by `eta_signal_stream`.

The public endpoint type is:

```ocaml
module type Stream_source = sig
  type 'a signal
  type 'a observer
  type 'a update
  type 'a delivery
  type observer_error

  val observe_delivery :
    ?cutoff:'a Cutoff.t ->
    ?on_finish:(observer_finish -> unit) ->
    'a signal ->
    ('a delivery -> (unit, observer_error) Eta.Effect.t) ->
    ('a observer, graph_error) Eta.Effect.t

  val current :
    'a delivery ->
    ('a update option, 'error) Eta.Effect.t

  val acknowledge :
    'a delivery ->
    (unit, 'error) Eta.Effect.t

  val dispose :
    'a observer ->
    (unit, graph_error) Eta.Effect.t
end
```

`Signal.For_stream` aliases the graph's signal, observer, update, and callback
error types. Its delivery value contains no public observer, token, or cursor.

`current` reads the event captured for that delivery. It returns `None` after
lifecycle finish or replacement by a newer event.

`acknowledge` uses the captured event identity. It changes pending delivery to
delivered during one graph-lane transition.

`Eta_signal_stream.Make(Signal.For_stream)` exposes:

```ocaml
val observe :
  ?capacity:int ->
  ?on_drop:('a Signal.update -> unit) ->
  ?cutoff:'a Cutoff.t ->
  'a Signal.signal ->
  ( 'a Signal.observer
    * ('a Signal.update, [ `Invalid_scope ]) Eta_stream.Stream.t,
    stream_error )
  Eta.Effect.t

val with_observed :
  ?capacity:int ->
  ?on_drop:('a Signal.update -> unit) ->
  ?cutoff:'a Cutoff.t ->
  'a Signal.signal ->
  (('a Signal.update, [ `Invalid_scope ]) Eta_stream.Stream.t ->
   ('b, 'err) Eta.Effect.t) ->
  ('b, [> stream_error ] as 'err) Eta.Effect.t
```

`eta_signal_stream` owns this exact error:

```ocaml
type stream_error =
  [ Eta_signal.graph_error
  | `Invalid_capacity ]
```

Capacity defaults to 1,024 and must be positive. Publication is nonblocking and
drops the newest update when the queue is full.

The bridge masks interruption across queue send or terminal drop, drop
diagnostics, and `acknowledge`. Observer retry duplicates neither outcome.

`on_drop` is diagnostics only. If it raises, the bridge logs the defect,
acknowledges the drop, and does not retry the hook.

Disposal closes the stream cleanly after buffered updates drain. Invalid scope
closes it with `Invalid_scope`.

`with_observed` disposes on every exit. Direct `observe` returns the observer as
the explicit demand handle.

The stream can cross domains because its queue is cross-domain. Graph operations
and the observer handle remain owner-domain-only.

The bridge does not copy payloads. Consumers own payload portability.

Eta adds no stream-to-signal operation. Such an adapter needs explicit initial,
close, failure, buffering, coalescing, and stabilization policies.

## Time

Time remains an engine-owned module in `eta_signal`:

```ocaml
type time_error =
  [ graph_error
  | `Deadline_overflow
  | `Invalid_interval
  | `Past_deadline ]

module Time : sig
  type monotonic_time

  val to_ms : monotonic_time -> int

  val add :
    monotonic_time ->
    Eta.Duration.t ->
    (monotonic_time, [ `Deadline_overflow | `Past_deadline ]) result

  val now :
    every:Eta.Duration.t ->
    (monotonic_time signal, time_error) Eta.Effect.t

  val deadline :
    monotonic_time ->
    (bool signal, time_error) Eta.Effect.t

  val after :
    Eta.Duration.t ->
    (bool signal, time_error) Eta.Effect.t

  val interval :
    Eta.Duration.t ->
    (int signal, time_error) Eta.Effect.t
end
```

Time uses the Eta runtime's monotonic clock. Values from different runtimes do
not compare or schedule together.

`now` samples at `every`. `deadline` and `after` sleep to one exact deadline and
expose no polling interval.

`interval` coalesces missed cadence updates arithmetically. Its counter saturates
at `max_int`.

Time nodes are demand-owned and never call `stabilize`.

Delete `step` and `step_replay`. They mix state-machine and catch-up policy into
the monotonic source algebra and add a distinct daemon-defect boundary.

Applications can combine `interval` with ordinary effects when they need state
advancement. Exact replay needs its own bounded workload and contract.

## Diagnostics

Keep read-only diagnostics in the graph result:

```ocaml
type stable_family_stats = {
  node_count : int;
  committed_child_count : int;
}

type stats = {
  snapshot_commit_count : int;
  callback_delivery_count : int;
  total_node_count : int;
  retained_invalid_node_count : int;
  necessary_node_count : int;
  dirty_node_count : int;
  active_observer_count : int;
  invalid_observer_count : int;
  active_timer_count : int;
  recompute_count : int;
  dynamic_scope_invalidation_count : int;
  stable_family : stable_family_stats;
}

val stats : unit -> (stats, graph_error) Eta.Effect.t
val to_dot : ?options:dot_options -> unit -> (string, graph_error) Eta.Effect.t
```

The record contains stable operational state only. Family comparison counts,
rollback counts, lane waiters, scheduler work, and tombstone scan counts remain
private test metrics.

The public record does not grow without a named consumer task. Ticket 16 can use
private counters for deterministic economics gates.

DOT includes graph structure and bounded metadata. It never includes values,
keys, closures, history, journals, or mutation controls.

## Failures and defects

Add `Domain_mismatch` to `graph_error`. Synchronous wrong-domain calls raise
`Graph_error Domain_mismatch` instead of `Invalid_argument`.

Synchronous construction operations raise `Graph_error` for expected graph
contract failures. Effectful operations return expected failures through their
Eta error channel.

Keep operation-specific observer-read, stabilization, time, and stream error
families. Do not collapse them into one universal error.

`Counter_overflow` remains a named graph error. Counters never wrap.

Pure map, bind, reduction, cutoff, and stable-family callback exceptions are Eta
defects. A pre-commit defect rolls back the attempt.

Observer update failures remain typed `Observer_error` after commit. Observer
callback exceptions remain defects. Their retry state stays pending.

Finish-hook exceptions remain post-finish defects. Stream drop-hook exceptions
remain logged, acknowledged diagnostics.

Impossible internal invariant failures remain defects, not public error
variants.

F1, N1, N2, and N5 need no public success-type or abstract signal-type change.
N5 keeps the committed-snapshot and post-commit failure semantics.

## Finding dispositions

- F4 is amended. Add a separate exactly-once finish hook. Reject `Unnecessary`
  and lifecycle variants inside value updates.
- F8 is accepted through one balanced associative reduction with O(log(n + 1))
  changed-leaf work. Reject the delta fold without stronger algebra.
- F9 is rejected as a parity batch. Delete shallow `both` and add no parity
  aliases or optional subsystems without separate contracts.
- F11 is rejected. Branch invalidation remains the only bind contract.
- F12 is split. Accept immutable named cutoffs and delete `?equal`. Reject runtime
  mutation, so cutoff reevaluation has no V1 answer.

## Evidence

- `lib/signal/eta_signal.mli:262-373` contains variables and observers.
- `lib/signal/eta_signal.mli:375-541` contains scalar and dynamic combinators.
- `lib/signal/eta_signal.mli:543-587` contains stabilization and diagnostics.
- `lib/signal/eta_signal.mli:589-700` contains the current time subsystem.
- `lib/signal/eta_signal.mli:702-766` contains the current stream bridge.
- [Ticket 10](10-scheduler-demand-and-topology.md#answer) defines reduction and
  timer work ownership.
- [Ticket 11](11-observer-delivery-contract.md#answer) defines update delivery.
- [Ticket 12](12-engine-and-package-seams.md#answer) defines one graph factory and
  package adaptation.
- [Incremental interface reference](07-incremental-interface-reference.md#answer)
  separates core algebra from optional subsystems.

## Census rows resolved here

Ticket 13 resolves all 87 assigned rows.

### Resolution spans

| Census ID | Resolution span |
|---|---|
| EXE-004 | lines 407–408 |
| F01-035 | line 542 |
| F04-001 | lines 270–282 |
| F04-002 | lines 407–408 |
| F04-003 | lines 278–282 |
| F04-005 | lines 270–276 |
| F04-007 | lines 407–408 |
| F04-009 | lines 278–279 and 304–305 |
| F04-010 | lines 278–279 |
| F04-011 | lines 278–282 |
| F04-012 | lines 287–317 |
| F04-013 | lines 299–317 and 407–408 |
| F04-014 | lines 278–279 |
| F04-015 | lines 307–317 and 322–365 |
| F04-016 | lines 281–317 |
| F04-017 | lines 281–282 |
| F04-018 | lines 278–282 |
| F04-019 | lines 32–52 and 322–419 |
| F04-020 | line 673 |
| F04-021 | lines 337–365 and 407–408 |
| F08-003 | lines 216–227 |
| F08-004 | lines 216–238 |
| F08-005 | lines 248–249 |
| F08-006 | lines 248–252 |
| F08-007 | lines 229–244 |
| F08-009 | lines 248–252 |
| F08-010 | lines 240–241 |
| F08-011 | lines 216–252 and line 672 |
| F09-002 | lines 143–152 |
| F09-004 | lines 146–147 |
| F09-005 | lines 180–190 and 477–514 |
| F09-006 | lines 32–52 and 421–514 |
| F09-007 | lines 54–96 |
| F09-008 | line 152 |
| F09-009 | lines 25–30 and 143–152 |
| F09-010 | lines 180–187 |
| F09-013 | lines 248–252, 262–263, and 471–475 |
| F09-014 | lines 149–150 |
| F09-015 | lines 248–252 and 471–475 |
| F09-016 | lines 54–96 |
| F11-002 | lines 256–257 |
| F11-003 | lines 256–257 |
| F11-006 | lines 256–266 |
| F11-008 | lines 256–266 |
| F11-009 | lines 259–260 |
| F11-010 | lines 262–263 |
| F11-011 | lines 265–266 |
| F11-012 | lines 259–266 |
| F12-002 | lines 56–96 |
| F12-004 | lines 56–90 |
| F12-005 | lines 92–93 |
| F12-006 | lines 56–77 |
| F12-007 | lines 79–84 |
| F12-008 | lines 81–84 |
| F12-009 | lines 92–93 |
| F12-010 | lines 92–93 |
| F12-011 | lines 92–93 |
| F12-012 | lines 56–96 and line 670 |
| F12-013 | lines 92–93 |
| F12-014 | lines 81–96 and line 670 |
| F13-014 | lines 506–511 |
| N01-027 | line 542 |
| N01-028 | line 528 |
| N02-040 | line 542 |
| N05-020 | lines 542–543 |
| S05-003 | lines 256–266 |
| S11-001 | lines 281–317 and 407–408 |
| S11-002 | lines 278–279 |
| S15-001 | lines 54–96 |
| PLN-11-001 | lines 56–96 |
| PLN-11-002 | lines 92–93 |
| PLN-11-003 | lines 92–93 |
| PLN-11-004 | lines 81–96 and line 670 |
| PLN-12-001 | lines 216–244 |
| PLN-12-002 | lines 248–252 |
| PLN-12-003 | lines 240–241 |
| PLN-12-004 | lines 216–252 and line 672 |
| PLN-13-001 | lines 307–317 and 322–365 |
| PLN-13-002 | lines 278–282 |
| PLN-13-003 | lines 322–365 |
| PLN-13-004 | lines 287–419, 673, and 677–678 |
| DEF-002 | lines 545–555 |
| DEF-003 | lines 25–30 and 545–555 |
| DEF-004 | lines 256–266 |
| DEF-005 | lines 259–266 |
| Q07-001 | lines 92–93 |
| Q07-002 | lines 92–93 |

## Implementation consequences

1. Add `Eta_signal.Cutoff`, replace candidate equality, and delete constant equality.
2. Change `bind` to `bind ?cutoff ~f signal` and delete `both`.
3. Add the balanced reduction node, executable laws, and complexity gates.
4. Add optional observer updates and the exactly-once finish hook. Update callers directly.
5. Delete public unsafe observer reads, time steps, and cutoff mutation plans.
6. Narrow public diagnostics and rename keyed gauges to stable-family gauges.
7. Add `Domain_mismatch` and preserve operation-specific typed error families.
8. Publish `eta_signal_stream` and remove `eta_stream` from `eta_signal`.
9. Add the narrow `For_stream` adapter and preserve bridge acknowledgement.
10. Update Signal Map's data cutoff to use `Eta_signal.Cutoff.t`.
