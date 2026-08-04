# Eta Signal V1 specification

Status: implementation-ready

## 1. Purpose

This file is the consolidated specification for Eta Signal V1. It defines the
target public API, engine invariants, package seams, Eta Crux integration, and
acceptance gates.

The resolved Wayfinder tickets are the design record. This file is the
authoritative handoff contract for implementation. The tickets retain rationale,
evidence, rejected alternatives, and claim traceability.

## 2. Scope

This specification covers:

- `eta_signal`
- `eta_signal_map`
- `eta_signal_stream`
- the Eta Crux integration with Signal and Signal Map
- private Signal engine structure
- public laws and deterministic economics gates
- removal of superseded APIs and engine paths

This specification does not require compatibility with Jane Street Incremental.
It does not permit compatibility shims for current Eta Signal callers.

Applications own state and application policy. Eta owns effect description and
interpretation. Eta Signal owns graph behavior, atomic publication, demand,
scheduling, topology, lifecycle, and observation.

## 3. Package and graph model

The final package graph is:

```text
eta_signal -> eta, eta_observability
eta_signal_map -> eta_signal (= same release)
eta_signal_stream -> eta_signal (= same release), eta_stream, eta_observability
eta_crux -> eta, eta_observability, eta_signal, eta_signal_map
```

The root `eta` package must not depend on any Signal package. `eta_signal` must
not depend on Signal Map, Eta Stream, Eio, Cstruct, or Eta Crux.

`Eta_signal.Make` is the only graph factory. Each application of the functor
creates one distinct graph brand. Values from distinct graph brands cannot
compose.

A collection package adapts an existing graph:

```ocaml
module Signal = Eta_signal.Make (Observer_error) ()
module Signal_map = Eta_signal_map.Make (Signal.Package)
module Keyed = Signal_map.Keyed (Order)
```

There is no graph conversion, graph injection, second Signal Map factory,
general custom-node API, or public graph-mutation API.

## 4. Public scalar algebra

### 4.1 Cutoffs

`Cutoff` is outside the graph functor:

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

- `always` suppresses every candidate.
- `never` suppresses no candidate.
- `phys_equal` uses physical equality.
- `of_equal equal` calls `equal published candidate`.
- `of_compare compare` suppresses when the comparison returns zero.

Physical equality is the default optional cutoff. Cutoffs are immutable after
construction.

A producer cutoff controls cached publication and downstream propagation. An
observer cutoff controls changed-event delivery. An observer cutoff never
suppresses `Initialized`.

Public `?equal` arguments, `get_cutoff`, and `set_cutoff` do not exist.

### 4.2 Constructors

The scalar constructors are:

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

(* The direct form continues through map9. *)

val all :
  ?cutoff:'a list Cutoff.t ->
  'a signal list ->
  'a list signal

val bind :
  ?cutoff:'b Cutoff.t ->
  f:('a -> 'b signal) ->
  'a signal ->
  'b signal

val reduce_balanced :
  ?cutoff:'a Cutoff.t ->
  identity:'a ->
  combine:('a -> 'a -> 'a) ->
  'a signal array ->
  'a signal
```

Configuration labels come first. Pure functions precede signal arguments.
Mutable targets remain first in mutable operations.

`map2` through `map9` are direct static constructors. `both` is deleted.
Signal adds no `join`, `if_`, infix family, bind arity family, `map10`, freeze,
snapshot, memoization, or raw node handler.

Pure graph callbacks must be total and free of side effects. A callback
exception is an Eta defect.

### 4.3 Balanced reduction

`combine` must be associative at the observation boundary. `identity` must be
its left and right identity at that boundary.

Construction copies the input array. Reduction preserves array order. Empty
input publishes `identity`.

Initial evaluation takes O(n) combination work. One changed child takes
O(log(n + 1)) combination work.

The final cutoff applies only to aggregate publication. Internal tree cells do
not suppress candidates.

### 4.4 Variables and reads

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

`Var.value` returns the latest accepted source value. It includes an
unstabilized set.

`Observer.read` returns the last committed observed value. It never forces
recomputation. Raw signals are not readable.

Repeated `Var.set` calls before stabilization form the public update batch.
Signal exposes no separate batch handle.

### 4.5 Graph errors

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

Synchronous construction failures raise `Graph_error`. Effectful operations
return expected failures through their Eta error channel.

Wrong-domain synchronous calls raise `Graph_error Domain_mismatch`. Counters
never wrap.

Callback exceptions and impossible internal states are defects. They do not
become graph-error variants.

## 5. Stabilization and atomic publication

### 5.1 Atomic pass

The private atomic-pass interface has one operation:

```ocaml
val stabilize :
  graph ->
  runtime_contract ->
  (unit, stabilize_error) Eta.Effect.t
```

The graph phase is:

```ocaml
type phase =
  | Idle
  | Planning of planning_session
  | Delivering of delivery_session
```

There is no separately mutable transaction status. There is no observable
committed phase between planning and delivery.

The implementation allocates the transaction and planning workspace before it
changes `Idle`. Successful entry performs one phase-field assignment.

A transaction uses one fresh physical identity:

```ocaml
type transaction_id = unit ref
```

There is no transaction counter, stabilization token, or global allocator.

The effect installs its finalizer before planning starts. After commit, the
finalizer owns the `Delivering` session until the graph returns to `Idle`.

### 5.2 Planning

Planning produces either one sealed commit plan or one rejection:

```ocaml
type planning_rejection =
  | Graph_error of graph_error
  | Defect of exn * Printexc.raw_backtrace

type planning_result =
  (sealed_commit_plan, planning_rejection) result
```

The plan contains:

- one immutable closed invalidation frontier
- commit and discard partitions for each dynamic operation
- prepared staged-cell, topology, scope, demand, timer, and observer state
- prepared counter changes
- one post-commit cleanup and lifecycle batch
- one declarative mutation tape

Each dynamic operation has exactly one owner node. Bind owns its bind node.
Stable-family work owns its family parent.

Planning discovers operations and retirement roots to a fixed point. Frontier
closure partitions every operation before topology publication.

Discard work runs while rollback remains legal. It clears staged state and
transfers attempt-owned resources to the cleanup ledger.

Planning validates the complete prospective topology. A prospective edge never
enters committed adjacency before validation succeeds.

### 5.3 Total commit

Only a sealed and fully validated mutation tape can change committed state.
The tape contains engine-owned writes, not callbacks.

Commit performs fixed writes and pointer replacements. It publishes observer
delivery state and changes the phase to `Delivering`.

Commit performs no:

- user callback
- graph traversal
- validation
- dynamic classification
- result-producing operation
- allocation-dependent planning

Commit cannot return a graph error. Rollback exists only during `Planning`.
`Delivering` has no rollback path.

### 5.4 Failure behavior

A planning error or defect must:

- preserve the previous committed snapshot and topology
- discard staged state
- terminate provisional resources once
- restore retryable work
- return the graph to `Idle`
- preserve the primary error, defect, and backtrace

A post-commit failure, defect, or interruption must:

- preserve the committed snapshot and topology
- never call rollback
- drain mandatory cleanup once
- retain only eligible pending observer delivery
- return the graph to `Idle`

Cleanup invokes every claimed hook once. One hook failure does not skip later
hooks. Failures are aggregated in invocation order after the primary cause.

## 6. Scheduling, topology, and demand

### 6.1 Work admission

One graph-owned ledger counts actionable work classes:

- necessary-stale scheduler work
- observer initialization or pending delivery
- timer-source updates
- topology and demand transitions
- pending cleanup
- future private node-kind work

Stabilization checks quiescence in O(1). A quiescent call performs no phase
entry, snapshot increment, registry scan, observer scan, root traversal, or
timer scan.

The weak live-node registry is diagnostic state. It is not a work index.

### 6.2 Necessary-stale scheduler

Each node stores dirty and scheduled state. A necessary clean-to-dirty
transition admits the node once to a graph-owned intrusive FIFO deque.

The scheduler uses explicit-stack dependency-first traversal. Every necessary
dirty dependency settles before its consumer.

Each attempt marks a node `Unseen`, `Visiting`, or `Done`. Reaching `Visiting`
reports `Cycle` before publication.

A cutoff that suppresses a candidate does not propagate work. Scheduling order
is deterministic for diagnostics, but it is not public value semantics.

### 6.3 Demand

Each node stores this demand reference count:

```text
observer references + necessary-parent edge references
```

A zero-to-one transition makes the node necessary and propagates demand through
its dependency edges. A one-to-zero transition removes those references.

Other count changes do not traverse dependencies. Counts use checked
arithmetic and cannot become negative.

Each edge contributes one demand reference exactly when its final parent is
necessary. Topology and demand changes publish in the same mutation tape.

### 6.4 Topology

The graph is a directed multigraph. Each constructor argument slot owns one
edge, including repeated child arguments.

A static node stores an immutable edge array in argument order. Every node
stores dependents in a geometrically grown dense vector.

Dynamic nodes store dense dynamic-edge vectors. Each edge records its parent,
child, graph identity, static or dynamic slot, and dependent-vector slot.

Removal swaps the final vector entry into the removed slot and repairs that
edge record. Removal performs no adjacency search or list filtering.

The required bounds are:

| Operation | Required work |
|---|---|
| Quiescent stabilization | O(1) |
| Dirty-frontier stabilization | O(Vw + Ew + Pc) |
| Demand zero-boundary change | O(Vd + Ed) |
| Demand change without zero crossing | O(1) |
| Static node with `n` edges | O(n) |
| Dynamic edge insertion | O(1) amortized, excluding cycle validation |
| Dynamic edge removal | O(1) adjacency work |
| `k` keyed removals | O(k) adjacency work |
| Whole-node invalidation | O(complete degree) |
| Prospective cycle validation | O(Vr + Er) |

One tri-color search validates the union of changed prospective frontiers.
Removing an edge needs no cycle search.

## 7. Dynamic composition and stable families

### 7.1 Bind

`bind` always retires the previous branch scope before it attaches the new
branch. Signal exposes no rescope mode.

A bind operation commits only when its owner survives frontier closure. A bind
under a retired owner discards its provisional branch and staged state.

Nested bind changes converge in one stabilization. A failed attempt preserves
the previous branch and can retry.

### 7.2 Package protocol

Every graph result exposes one opaque, graph-branded `Package` endpoint:

```ocaml
module type Package_graph = sig
  type 'a signal
  type 'a plan

  type 'a change =
    | Left of 'a
    | Right of 'a
    | Changed of 'a * 'a

  type ('key, 'data, 'map) input_ops = {
    empty : 'map;
    compare_key : 'key -> 'key -> int;
    fold_symmetric_diff :
      'acc.
      'map ->
      'map ->
      on_compare:(unit -> unit) ->
      init:'acc ->
      f:('acc -> 'key -> 'data change -> 'acc) ->
      'acc;
  }

  type ('key, 'output, 'map) output_ops = {
    empty : 'map;
    set : 'key -> 'output -> 'map -> 'map;
    remove : 'key -> 'map -> 'map;
  }

  val stable_family :
    input:'data_map signal ->
    input_ops:('key, 'data, 'data_map) input_ops ->
    output_ops:('key, 'output, 'output_map) output_ops ->
    ?data_cutoff:'data Cutoff.t ->
    build:(key:'key -> data:'data signal -> 'output signal) ->
    unit ->
    'output_map plan

  val install : 'a plan -> 'a signal
end
```

`compare_key` defines total stable order and key identity. Symmetric diff emits
each changed key once in increasing order.

The adapter supplies pure diff, cutoff, builder, and persistent-map operations.
The engine owns all graph state and authority.

Package code cannot obtain a graph, node, edge, scope, phase, transaction,
scheduler, queue, demand handle, or mutation handle.

Package callbacks run only during planning. Duplicate or contradictory edits
are planning defects.

## 8. Observers

### 8.1 Public API

```ocaml
type 'a update =
  | Initialized of 'a
  | Changed of { old_value : 'a; new_value : 'a }

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

An observer without `on_update` still owns demand and current committed state.
`Observer.unsafe_read_exn` is deleted.

`on_finish` runs exactly once after terminal state. Finish clears pending
delivery before the hook runs. Finish-hook exceptions are defects.

### 8.2 Delivery order

Callbacks follow one deterministic total topological plan:

1. Dependencies precede transitive consumers.
2. Same-signal observers use ascending observer identity.
3. Ready unrelated groups use their smallest observer identity.
4. Remaining ties use signal identity, then observer identity.

Planning uses a Kahn-style traversal over the final prospective topology. An
array-backed binary min-heap selects ready candidate groups.

The planner performs no pairwise reachability comparison. Registration order
does not change callback order.

### 8.3 Snapshot, retry, and finish

Every callback in one plan observes the same committed snapshot. Source updates
from callbacks become visible only after a later explicit stabilization.

Each observer owns:

- its last successfully delivered value
- its latest committed current value
- at most one pending update and delivery token
- pending or running delivery state

Collection coalesces from the last delivered value to the latest committed
value. A never-delivered observer receives `Initialized`.

Delivery is sequential and fail-fast. The first typed failure, defect, or
interruption stops the remaining plan.

Acknowledgement, finish, and failure release are linearized by the graph lane.
The first lane mutation wins.

Delivery is at least once while the observer remains active. A sealed delivery
capability can acknowledge after durable send or terminal drop.

Disposal does not cancel an already running callback. Its result cannot restore
a disposed cursor or create a retry.

Observer planning takes O(C + Vu + Eu + C log C). Delivery takes O(C).
Unrelated observers do not affect planning work.

## 9. Time

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

Time uses the runtime monotonic clock. Values from distinct runtimes do not
compare or schedule together.

One-shot timers use one exact deadline. `interval` coalesces missed periods
arithmetically and saturates at `max_int`.

Timer nodes are demand-owned. Daemon wakes enqueue source work and never call
`stabilize`.

A failed start leaves a queued lifecycle mismatch. A later graph effect retries
it. Stop fences the old generation before cancellation.

`Time.step`, `Time.step_replay`, and polling arguments on one-shot timers are
deleted.

## 10. Diagnostics and tombstones

Public diagnostics expose stable committed metadata:

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

Diagnostics must not change graph behavior. DOT and tombstones contain no user
values, keys, closures, logs, histories, or mutation controls.

Invalid-node diagnostics use a graph-allocated circular array with 1,024 slots.
The first valid-to-invalid node transition inserts one snapshot.

Insertion takes O(1). The ring performs no duplicate scan. A full ring replaces
the oldest snapshot. Iteration is newest first and visits at most 1,024 entries.

## 11. Signal Stream

Each graph result exposes a narrow sealed `For_stream` endpoint. It contains
only the observer-delivery capabilities required by `eta_signal_stream`.

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

```ocaml
type stream_error =
  [ Eta_signal.graph_error
  | `Invalid_capacity ]
```

Capacity defaults to 1,024 and must be positive. Publication is nonblocking.
A full queue drops the newest update.

Each offered update gets exactly one sent-or-dropped outcome and one
acknowledgement. Interruption cannot split that sequence.

A raising `on_drop` hook is logged as a defect. The bridge acknowledges the
drop and does not retry the hook.

Disposal closes the stream after buffered updates drain. Invalid scope closes
with `Invalid_scope`. `with_observed` disposes once on every exit.

The stream can cross domains. The observer handle and graph operations remain
owner-domain-only.

Signal exposes no stream-to-signal operation.

## 12. Eta Crux integration

Eta Crux public computations remain graph-neutral. Applications receive no
Signal module, signal value, observer, graph, scope, transaction, stabilization,
or package endpoint.

Each root creates:

1. one private `Eta_signal.Make` graph
2. one `Eta_signal_map.Make(Signal.Package)` adapter
3. one compiled root-frame signal
4. one private output observer without callbacks

The private root signal publishes one immutable frame:

```ocaml
type 'output frame = {
  output : 'output;
  endpoints : endpoint_manifest;
  lifecycle : lifecycle_manifest;
  sources : source_manifest;
}
```

The frame is the sole truth for endpoint validity and structural lifetime. The
final frame node uses `Cutoff.never`.

Each state machine owns one private Signal variable. `Assoc(Order).assoc`
compiles to `Signal_map.Keyed(Order).mapi`.

Continuous key presence preserves child identity, model, and endpoints. Removal
retires the incarnation. Re-entry creates fresh state and endpoints.

One non-idle advancement:

1. selects one event
2. validates endpoint incarnation
3. stages model and dormant transition effect
4. runs one Signal stabilization
5. reads the private candidate frame
6. builds and validates one immutable root commit
7. installs one root-commit pointer under the root lock
8. returns output and the mandatory post-commit token
9. lets the driver deliver output before token start

Idle advancement performs no stabilization. Signal snapshot commit is private
preparation. The root-pointer assignment is the Crux semantic commit.

A failure before pointer installation preserves the prior Crux frame. A defect
after installation crashes the root before output delivery.

Lifecycle and source effects run after root publication. Signal callbacks never
drive host adapters.

Crux timers remain ordinary Eta effects or sources that send typed endpoint
actions. Crux V1 exposes no Signal time description.

The custom Crux graph, `Owner_transaction`, and stale keyed paths are deleted.
No fallback backend remains.

## 13. Private engine ownership

One private Dune library under `lib/signal/engine/` contains all engine modules.
Each module owns exactly one named invariant.

| Module | Named invariant |
|---|---|
| `Eta_signal_atomic_pass` | Phase authority |
| `Eta_signal_transaction` | Atomic staging |
| `Eta_signal_commit_plan` | Total commit |
| `Eta_signal_cleanup` | Cleanup linearity |
| `Eta_signal_node` | One-way node lifetime |
| `Eta_signal_scope` | One-way scope lifetime |
| `Eta_signal_topology` | Edge consistency |
| `Eta_signal_demand` | Final demand contribution |
| `Eta_signal_observer_plan` | Deterministic delivery order |
| `Eta_signal_stable_family_plan` | Stable-family edit ownership |
| `Eta_signal_work` | O(1) quiescence |
| `Eta_signal_scheduler` | Frontier completion |
| `Eta_signal_observer` | Cursor uniqueness |
| `Eta_signal_observer_delivery` | Delivery termination |
| `Eta_signal_timer_policy` | Desired timer state |
| `Eta_signal_timer` | Timer generation fence |
| `Eta_signal_lane` | Exclusive effectful graph access |
| `Eta_signal_id` | Identity-role separation |
| `Eta_signal_error` | Failure classification |
| `Eta_signal_diagnostics` | Diagnostic noninterference |
| `Eta_signal_tombstone_index` | Bounded invalid-node retention |
| `Eta_signal_test_probe` | Graph-branded typed inspection |
| `Eta_signal_kernel` | Sole graph construction |

`Eta_signal_kernel` is the composition root. It connects concrete node kinds
and owned states. It does not contain owner algorithms.

Delete forwarding wrappers, one-adapter port records, and obsolete algorithm
functors. A private seam remains only when:

1. it owns one named invariant
2. its type rejects an illegal phase transition
3. it supports two real adapters under one contract
4. OCaml needs it for rank-2 polymorphism

Use count does not decide retention.

The target removes `Eta_signal_graph`, `Eta_signal_graph_algorithms`, both old
stabilization modules, `eta_signal_support`, and all obsolete port protocols.

## 14. Executable acceptance gates

### 14.1 Law registry

Every final normative interface claim must have:

- one exact source span in the executable-law registry
- one named executable property or registered authoritative test
- an explicit observation boundary
- a generated class with a discriminating case

No changed interface can use new dated debt. Delete stale rows with deleted
APIs. Replace blanket Signal debt `D-E22-004` with claim-level rows.

Every effectful property with no legitimate background work ends with an
available empty fiber census. Timer and stream properties do the same after
teardown.

### 14.2 Required defect regressions

The suite must include:

- atomic phase-entry allocation failure with idle-state preservation
- generated planning faults at all eight declared planning slots
- generated post-commit exits with no rollback
- all five mixed keyed-removal and nested-bind scenarios
- the `A < C < B` observer-order counterexample
- lane-linearized acknowledgement, finish, and failure-release races
- timer generation, lifecycle retry, and exact-deadline cases
- stream outcome, acknowledgement, capacity, and disposal cases

Generated failures print the seed, class, operation tape, expected observation,
actual observation, and private census.

### 14.3 Economics gates

Economics tests use fresh graph instances, independent fixture manifests, typed
probes, owner-local counters, and one measured operation tape.

The exact size series is 1,000, 10,000, and 100,000 nodes or edges. Wall time is
benchmark evidence only.

The required deterministic gates cover:

- constant quiescent stabilization
- narrow and half-graph frontier proportionality
- nested-bind frontier bounds
- one-child stable-family updates
- observer candidate-union bounds
- independence from unrelated observers
- queued-only timer reconciliation
- linear wide-node attachment and invalidation
- linear keyed removals
- logarithmic balanced-reduction leaf changes
- constant tombstone insertion

These counters must remain zero:

```text
adjacency_search_steps
pairwise_search_visits
duplicate_scan_steps
```

Tombstone slot writes must equal invalidated-node transitions.

### 14.4 Dune aliases

The repository provides:

```text
@signal-laws
@signal-economics
@signal-gates
```

`@signal-gates` depends on generated laws, defect regressions, deterministic
economics, stream laws, and Signal Map complexity gates.

OxCaml and mainline shipped gates run `@signal-gates`. Wall-time benchmarks
remain under `@bench`.

## 15. Implementation route

Implement these slices in order. Each slice deletes its old behavior path.

1. Add final requirement rows, law names, probes, counters, and fault slots.
2. Add physical transactions, atomic pass, cleanup, sealed commit plans, and
   one-way node and scope lifetime.
3. Add indexed topology, incremental demand, work ledger, and scheduler.
4. Move bind and stable-family edits into the closed frontier. Adapt Signal Map
   through `Signal.Package`.
5. Add named cutoffs and balanced reduction. Delete raw equality and `both`.
6. Add topological observer planning, durable cursors, acknowledgement, and
   exactly-once finish.
7. Replace timer scans with queued reconciliation. Delete obsolete time APIs.
8. Add committed diagnostics and the fixed tombstone ring.
9. Publish `eta_signal_stream` and delete the core stream bridge.
10. Migrate Eta Crux to one private Signal graph and one Signal Map adapter.
11. Delete obsolete libraries, protocols, tests, requirements, and registry rows.
12. Run `@signal-gates`, full OxCaml tests, mainline tests, and shipped gates.

No slice keeps a compatibility path, fallback backend, or silent default.

Implementation is complete only when:

- all final law rows have named executable evidence
- all N1 through N5 regressions pass
- all economics gates pass at every specified size
- effectful teardown cases end with an empty fiber census
- no deleted API or obsolete private protocol remains
- Eta Crux uses only the final public Signal and Signal Map contracts
- `@signal-gates` passes on OxCaml and mainline

## 16. Design sources

The resolved tickets retain rationale, rejected alternatives, evidence, and
claim-census traceability:

- [Transaction and invalidation model](issues/09-transaction-and-invalidation-model.md)
- [Scheduler, demand, and topology model](issues/10-scheduler-demand-and-topology.md)
- [Observer delivery contract](issues/11-observer-delivery-contract.md)
- [Engine and package seams](issues/12-engine-and-package-seams.md)
- [Public Eta Signal algebra](issues/13-public-signal-algebra.md)
- [Eta Crux Signal contract](issues/14-eta-crux-signal-contract.md)
- [Internal module ownership](issues/15-internal-module-ownership.md)
- [Laws and economics gates](issues/16-laws-and-economics-gates.md)
- [Review disposition and implementation route](issues/17-review-disposition-and-route.md)
