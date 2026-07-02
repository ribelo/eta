# PRD: eta_signal Incremental FRP Package

## Status

Draft. This PRD is the active implementation target for the optional
`eta_signal` package. Implementation-time decisions and gaps that need human
review are recorded in the audit notes at the end.

## Problem Statement

Eta users have effects, schedules, queues, pubsub, streams, and mutable refs,
but they do not have a small fine-grained reactive state engine for derived
state.

`Mutable_ref` stores a value but has no dependency graph. `Pubsub` and `Stream`
move events but do not cache derived values or provide a stabilization
boundary. A consumer can wire these primitives together manually, but a correct
reactive graph has subtle protocol concerns: dependency ordering, cutoffs,
dynamic dependencies, observer execution, batching, disposal, and failure
propagation.

The intended capability is not a SolidJS clone and not a UI framework. The
intended capability is an Incremental-like FRP substrate built on top of Eta:
explicit graphs, explicit stabilization, ordinary OCaml values in the graph,
and `Effect.t` as the contract for runtime interaction.

The implementation should be a close semantic rewrite of Jane Street
Incremental adapted to Eta primitives and Eta's effect contract, not a
dependency on Incremental or Jane Street libraries. The local
`.reference/incremental` checkout is the primary implementation prior art.

## Goals

- Provide a minimal fine-grained reactive graph package named `eta_signal`.
- Keep root `eta` independent of `eta_signal`.
- Build on Eta effects for graph mutation, stabilization, observers, and
  disposal.
- Keep derived graph values as ordinary OCaml values.
- Support explicit stabilization as the only core propagation mechanism.
- Support static derived nodes and explicit dynamic dependencies.
- Support deterministic effectful observers.
- Support per-node cutoffs to avoid unnecessary downstream propagation.
- Support time/clock nodes driven by existing Eta runtime primitives.
- Preserve OCaml-friendly graph ownership with functorized graph instances.

## Non-Goals

- No global ambient graph.
- No SolidJS-style implicit dependency tracking in the target contract.
- No automatic stabilization in the kernel.
- No public batch/transaction primitive; explicit stabilization is the batching
  boundary.
- No UI framework, DOM model, TEA framework, or renderer.
- No STM.
- No cross-graph dependencies in the target contract.
- No first-class graph value surface in the target contract; graph identity is
  provided by functorized modules.
- No separate timing wheel or private scheduler inside `eta_signal`.
- No direct dependency from root `eta` to `eta_signal`.
- No use of `eta_signal` from root `eta`; optional and higher-level Eta
  packages may use `eta_signal` after the package is proven.
- No JavaScript-specific performance assumptions as implementation proof.
- No promise that the target contract is as broad as Jane Street Incremental.
- No broad copy of Incremental's combinator library before consumer pressure:
  `freeze`, `snapshot`, collection folds, keyed merges, and similar helpers are
  outside the target unless a concrete Eta use case requires them.
- No public `Expert` surface in the target contract. Custom-node machinery stays
  internal until a real adapter requires a separately tested expert layer.
- No public scope save/restore surface in the target contract. Bind scopes stay
  internal unless a future expert layer proves a narrow need.

## Agreed Decisions

### Values and Effects

Signals carry ordinary OCaml values. Variables, signals, and observers are
distinct public concepts.

Signals compose graph structure. They are not the public value-read handle for
derived state. Observer handles are the value-read surface for initialized
stabilized values.

Source variables may expose their most recently set source value directly. That
read is separate from reading derived graph values and does not imply graph
recomputation.

Operations that interact with graph state, observers, lifecycle, or runtime
behavior return Eta effects. This includes source mutation, stabilization,
observer registration/disposal, and effectful updates.

Computed nodes are pure and synchronous. Effectful work belongs in
observers or explicit update operations, not inside derived pure nodes.

### Explicit Stabilization

The kernel uses explicit stabilization. `set` marks sources dirty. It does not
propagate immediately and does not run observers.

Public Eta source mutation from observer callbacks and other observer/effect
phase operations during stabilization is allowed but delayed. It behaves as if
the mutation happened immediately after the current stabilization completes, so
the new source value is not visible to derived nodes or observers until the
next explicit stabilization.

Pure recompute functions remain synchronous and do not receive an Eta effect
context. They cannot perform public source mutation as part of recomputation;
effectful graph work belongs in observers or explicit update operations.

Multiple source mutations before one stabilization are the batching mechanism.
There is no separate public batch or transaction primitive in the target
contract.

`stabilize` is the transaction boundary:

- recompute observed dirty graph in dependency order;
- apply cutoffs;
- update cached values;
- collect observer update events;
- run observers whose observed values changed;
- return through `Effect.t`.

Stabilization is two-phase. The pure graph recomputation phase reaches a stable
snapshot first. Observer callbacks run only after that snapshot exists, in the
effect phase.

Pure graph snapshot publication is atomic. Failed pure recomputation does not
publish a partial snapshot. Observer effects are not transactional: callbacks
that already ran are not rolled back or compensated if a later observer fails.

Automatic behavior can be built as an adapter that calls `stabilize` at chosen
loop boundaries. The core package must not assume a browser-like event loop.

### Core Algorithm

The semantic core follows Jane Street Incremental's explicit stabilization
model: push invalidation when sources change, then pull recomputation during
stabilization.

Source mutation marks sources changed and makes necessary dependents stale; it
does not recompute derived values. Stabilization processes necessary stale nodes
in deterministic topological or height order. Each node reads already-stable
children, recomputes at most once per stabilization, applies its cutoff, and
only propagates change when its value changed by cutoff.

Pure pull is not the target because value reads must not become recomputation
points. Eager push is not the target because it violates manual batching and can
compute intermediate states that no observer should see. Alien Signals is useful
implementation prior art for intrusive dependency links and dirty flags, but
its automatic JS-style effect scheduling is not the semantic model for Eta.

### Reentrancy

Each graph has a single mutation/stabilization lane. Source mutation,
effectful update, observer registration/disposal, timer source updates, and
stabilization enter that lane and are serialized per graph. Observer-handle
reads are read-only: they do not trigger recomputation, stabilization, or graph
mutation.

Waiting to enter the graph lane is interruptible. If a waiting fiber is
interrupted, its queued graph operation is removed and must not run later. If
interruption happens while an operation is active, Eta interruption propagates
normally and cleanup releases the lane.

Stabilization is non-reentrant. Calling stabilization while the same graph is
already stabilizing fails with a clear typed graph error instead of blocking,
nesting, or silently doing nothing.

Effectful update is non-reentrant per variable. Re-entering effectful update on
the same variable from inside its update callback fails with a clear typed graph
error instead of deadlocking. Updates to other variables still follow the normal
mutation rules.

Observer callbacks may call ordinary mutation operations. Those mutations mark
sources dirty for the next explicit stabilization; they do not mutate the
snapshot currently being observed.

### Functorized Graph Instances

The primary interface is a functorized graph instance. Each functor application
owns an independent graph.

The graph is not passed as a value to every constructor, there is no first-class
graph value in the main surface, and there is no hidden global graph. This uses
OCaml's module system for graph isolation.

### No Cross-Graph Dependencies

Values from different functor applications do not compose directly. One graph
is one stabilization domain.

Cross-graph data flow, if needed, is an explicit edge outside the kernel:
observe or read from one graph, then set a variable in another graph.

### Explicit Dependency Combinators

The target contract is Incremental-like, not Solid-like. Dependencies are described by
named combinators: constants, watching variables, unary mapping, n-ary mapping,
pairing, homogeneous collection joining, and explicit dynamic binding.

The n-ary maps are not only call-site sugar: they let the graph represent an
n-input pure computation as one node instead of building intermediate tuple
nodes with `both` plus `map`. The target contract includes `map2` through
`map9`, `both`, and `all`. `map10+` and specialized collection folds are not
part of this contract unless separate evidence shows sustained pressure for
them.

There is no `computed : (unit -> 'a) -> 'a signal` that tracks dependencies by
intercepting reads.

### Failure and Defect Propagation

Errors propagate through Eta's existing effect model. Typed failures remain
typed failures. Defects remain defects. Interruption remains interruption.
Finalizer diagnostics propagate according to ordinary Eta semantics.

The catch boundary is the effect-returning public operation, not each graph
node. In particular, exceptions raised by user callbacks during stabilization
are captured as defects of the stabilizing effect. This includes mapping
functions, dynamic dependency selectors, cutoff predicates, and observer
callback construction. A failed stabilization does not publish a half-updated
snapshot.

`Time.step` callbacks are not stabilization callbacks. They run in
demand-owned timer daemons that update backing sources, so step callback
defects are reported as daemon diagnostics rather than as `stabilize` failures.
Failed timer daemons clean up their timer state so a later demand refresh can
restart them.

Eta does not copy Incremental's permanent poisoning behavior after callback
exceptions. A callback exception fails the current operation as an Eta defect,
preserves the last stable snapshot, and leaves the graph available for a later
stabilization retry.

Invalid state should be unrepresentable where OCaml types can express the
constraint. When that is not possible, expected public operation failures use
small `eta_signal` typed error families instead of generic exceptions or string
defects. This includes invalid observer reads, cycle detection, reentrant
stabilization, and same-variable effectful update reentry.

Error families should stay scoped to operation groups rather than collapsing
into one catch-all graph error. Observer-read errors, graph-operation errors,
and time/clock construction errors should be separate unless a public operation
can actually produce more than one family. Each family needs a clear
pretty-printer.

Expected observer-read errors include uninitialized observer, disposed observer,
and no current value after a failed stabilization. Expected graph-operation
errors include cycle detection, reentrant stabilization, and same-variable
effectful update reentry. Expected time errors include invalid intervals and
deadlines already in the past when such operations are exposed.

Defects are reserved for exceptions raised by user callbacks and for impossible
internal invariant violations that should not be recoverable public states.

### Dynamic Dependencies

The target contract includes explicit `bind` as the dynamic dependency
primitive.

`bind source f` depends on `source`. When `source` changes and passes cutoff,
the node detaches from the old inner signal, attaches to the signal returned by
`f current`, and exposes that inner signal's current value.

`bind` requires Incremental-style scopes and invalidation. Nodes created while
the dynamic dependency selector runs are associated with that selector scope.
When the source changes, the old scope is invalidated, old inner dependencies
become unnecessary, and old inner nodes are not recomputed just to discover that
they are obsolete.

Node creation during stabilization is allowed only when the current scope is
well-defined. Nodes created while a bind selector runs belong to that bind
scope. Nodes created elsewhere during stabilization must either attach to the
current scope when that is unambiguous or fail with a typed graph error. The
implementation must not silently attach dynamic nodes to the wrong scope.

Scope capture and restoration are internal mechanisms. The main public surface
does not expose `Scope.current`/`Scope.within`-style operations.

`bind` is expected to be more expensive than `map`/`map2` and should be
documented as the graph-changing primitive.

Cycles are invalid and fail with a typed graph error.

### Effectful Updates

The target contract includes a single effectful update primitive for serialized
source mutation that must run an Eta effect before deciding the stored value.

Semantics:

- updates to a variable are serialized;
- the callback sees the current value;
- on success, the new value is stored and published to the graph exactly once;
- on typed failure, defect, or interruption, the value is unchanged;
- cleanup releases the update slot.

### Observers

The target contract exposes explicit effectful observers. Observer callbacks
receive either an initialization event with the current value or a changed event
with the previous and new values.

Observers are opaque handles, not just callback registrations. The handle is
the demand token that keeps the observed subgraph necessary, and it is the
lifecycle token used to stop future observation. Callback-only observation is
not the target contract.

Observer handles expose the last stabilized observed value after
initialization. Reading through the observer makes liveness explicit: the value
is available because the handle keeps the observed subgraph necessary.

The primary observer read is an Eta effect. Invalid observer state, such as
reading before initialization, reading after disposal, or reading after a failed
stabilization that left no current value, is reported through a typed
observer-read error rather than by silently returning stale data. An unsafe
synchronous read may exist for tests and debugging, but it is not the primary
consumer surface.

Observer semantics:

- registering an observer does not run its callback immediately;
- registration attaches demand and returns the observer handle, but does not run
  user observer code;
- the first later `stabilize` initializes the observer and runs
  `Initialized current_value`;
- observers run only during the effect phase of `stabilize`;
- observers see stabilized values, not intermediate updates;
- after initialization, observer callbacks run with `Changed` only when the
  observed value changes by cutoff;
- observer events are collected after pure graph propagation reaches a stable
  snapshot;
- observer callbacks run sequentially in deterministic graph order;
- multiple observers of the same signal run in registration order;
- independent graph regions use a stable internal tie-breaker;
- typed observer failure makes `stabilize` fail;
- defects and interruption propagate normally;
- observers that already ran before a failure are not rolled back;
- observers after a fail-fast observer failure do not run;
- observer callbacks may call `set` or other mutation operations, but those
  changes are deferred to the next explicit `stabilize`;
- observer-handle reads during observer callbacks still see the snapshot
  produced by the current stabilization;
- disposal removes the observer from future stabilizations.

The target contract does not include an `Invalidated` update event. Observer
disposal is explicit and does not invoke callbacks.

Eta copies Incremental's observer liveness model, but not Incremental's default
finalizer contract. Explicit disposal is the portable public contract. A native
or js_of_ocaml implementation may add best-effort finalizer cleanup if both
backends are verified, but correctness and timely release of demand must not
depend on GC timing.

### Liveness

Observers are the demand boundary. A signal becomes necessary when an observer
depends on it, directly or through derived nodes.

`stabilize` recomputes only the necessary dirty subgraph. Derived nodes with no
path to an observer are not recomputed during stabilization.

Derived value reads go through initialized observer handles. Reading an observer
does not make any additional signal necessary and does not force recomputation;
it returns the stabilized value maintained because the observer itself is the
demand token.

Raw signals have no public value read in the target surface. This avoids stale
or unnecessary derived reads becoming an accidental lazy-pull mechanism.

### Node Lifecycle

Ordinary derived nodes have no public delete operation. Creating a node does not
make it active work; observation and necessary dependency paths determine
whether it participates in stabilization.

Observer disposal and dynamic `bind` branch changes remove demand. When a node
has no path to an observer, it becomes unnecessary and is not recomputed. Nodes
created inside an old dynamic bind scope are invalidated when that scope is
replaced. They are not manually deleted one-by-one.

Memory is reclaimed by the OCaml runtime once user code and necessary graph
edges no longer retain the node. Retaining references to old nodes may keep
memory alive, but it must not keep those nodes active unless they are observed
or necessary.

External resources owned by dynamic graph regions, such as timer fibers or
subscriptions, must attach cleanup to observer disposal, scope invalidation, or
necessity loss rather than relying on node deletion.

### Cutoffs

The default cutoff is physical equality (`==`).

Producing nodes may accept custom equality. Node equality controls downstream
graph propagation.

User-facing examples that produce structural data should pass explicit
structural equality at the producer:

```ocaml
type view_model = {
  title : string;
  rows : string list;
}

let view_model_equal left right =
  String.equal left.title right.title
  && List.equal String.equal left.rows right.rows

let view_model_signal =
  Signal.map ~equal:view_model_equal derive_view_model model_signal
```

For pairs, prefer `map2 ~equal` over `both` when pair contents define the
logical value, because `both` has no `?equal` shortcut.

Observer registration may also accept custom equality. Observer equality
controls callback emission for that observer only; it does not change the
observed signal's propagation behavior for other consumers. Stream observation
uses the same observer cutoff; examples that bridge structural values should
pass the same structural equality there too:

```ocaml
let* observer =
  Signal.Observer.observe ~equal:view_model_equal view_model_signal
    handle_view_model_update

let* stream_observer, stream =
  Signal.Stream.observe ~equal:view_model_equal view_model_signal
```

Custom equality functions are user callbacks. If they raise, the active
operation fails as an Eta defect under the same no-partial-snapshot retry policy
as other user callback exceptions.

Rationale:

- physical equality is cheap;
- structural equality can be expensive, raise, or be inappropriate for
  functions/custom values;
- consumers can opt into structural/domain equality where it is correct.
- shared derived signals can keep cheap propagation while individual observers
  use domain-specific callback suppression.

### Stats and Debug Introspection

The target contract includes a small read-only stats and debug surface. A graph
engine needs this to diagnose demand leaks, unexpected necessity, recomputation
storms, and stale dynamic scopes.

The surface should expose cheap counters where possible: stabilization count,
active observer count, necessary node count, stale/recompute counts, dynamic
scope invalidation counts, and nodes becoming necessary or unnecessary. A DOT
dump or equivalent graph export for the necessary graph is acceptable for
debugging, but it must be read-only and clearly not part of normal propagation.

The debug surface must not expose mutation controls or alternate stabilization
paths.

### Stream Bridge

The target includes a one-way bridge from observed signal values to Eta streams.
The bridge emits the same initialized/changed updates as observers and preserves
explicit stabilization: updates enter the stream only after stabilization
reaches a stable snapshot and runs the observer effect phase.

The v1 public bridge is `Stream.observe ?capacity signal`, returning the
observer lifecycle handle and the stream. `capacity` defaults to 1024 and bounds
an Eta queue. Stream publication from stabilization is nonblocking; when the
queue is full, the newest stream update is dropped and stabilization continues.
This means slow or abandoned stream consumers can miss updates without blocking
other observers or graph progress.
Disposing the returned observer closes the stream after buffered updates drain.
Stopping, taking from, or abandoning the stream early does not dispose the
observer; the returned observer remains the lifecycle owner. The returned
stream is backed by Eta's same-domain queue and must be consumed on the graph
owner domain.

The target does not include a stream-to-signal bridge in the kernel. Converting
an arbitrary stream into a signal requires policy choices for initial value,
buffering, coalescing, backpressure, close semantics, failure mapping, and which
fiber drives stabilization. That belongs in a separate adapter after the kernel
contract is proven.

Incremental does not provide a generic stream-to-signal primitive in its core
surface. External producers enter the graph through variables or specialized
nodes, while stabilization remains explicit. Eta should follow that split: a
stream consumer may update a variable in a separate adapter with explicit
policy, but the kernel does not hide those choices.

### Time and Clock Nodes

The target includes time/clock nodes, but they are driven by Eta primitives that
already exist: runtime clock reads, `Duration`, `Effect.sleep`, `Schedule`, and
runtime-managed fibers. `eta_signal` must not introduce a separate timing wheel
or scheduler.

Eta runtime time is monotonic elapsed time, not civil/wall-clock time. Runtime
backends and test overrides must keep `now_ms` and `sleep` on the same
monotonic time base; mixing wall-clock reads with relative monotonic sleeps
makes clock-jump behavior undefined for schedules, timeouts, and signal timers.

Internal timer drivers may use Eta `Schedule`, but v1 does not expose a public
schedule-taking time-node constructor. Public time constructors use explicit
runtime-clock and duration arguments.

Time nodes preserve explicit stabilization. Timer effects may update clock
sources and mark dependent graph regions stale, but observer callbacks still run
only when stabilization is explicitly driven. Higher-level adapters may combine
sleep/update/stabilize loops when a consumer wants automatic time propagation,
but that is an adapter policy rather than the kernel's default behavior.

Time nodes do not call stabilization themselves. They are source-updating
effects, not a backdoor automatic propagation mechanism.

Time nodes are demand-driven. Constructing a time node does not start timer work
by itself. When the node becomes necessary, it may start Eta-managed timer work;
when it becomes unnecessary through observer disposal or dynamic dependency
invalidation, that work must stop or become inert.

Timer work is owned by graph demand, not by a global graph loop. A timer exists
because a necessary path needs it; it must not keep an otherwise unnecessary
subgraph alive.

The target should include Incremental-like clock semantics where useful:
watching the current runtime time, one-shot deadlines, relative delays,
interval ticks, and step functions. Their implementation must route through
Eta's runtime clock/sleep and test-clock facilities so native and js_of_ocaml
behavior remain portable and testable.

`Time.step` step functions run from the timer daemon that advances the backing
source. Their callback defects follow the timer-daemon diagnostic path described
above, not the stabilization callback failure path.

## Interface Shape

The surface is organized around a functorized graph module with opaque variable,
signal, and observer types.

The graph surface includes source creation and mutation, observer-handle value
reads, pure derived nodes, explicit dynamic dependencies, observer lifecycle,
and explicit stabilization.

The derived-node surface includes constants, watched variables, unary maps,
`map2` through `map9`, pairs, homogeneous collection joining, and explicit
dynamic binding. Derived nodes accept custom result cutoffs where useful.

The surface also includes time/clock derived nodes backed by Eta runtime time
and Eta schedules, without adding a hidden scheduler to the graph kernel.

The broad Incremental helper family is intentionally outside this target.
Additional helpers should be justified by actual Eta consumers or later porting
points, not copied wholesale.

Incremental-style `Expert` machinery is implementation prior art, not public
surface. Public users should not be able to bypass invariants for necessity,
invalidation, heights, scopes, or observer scheduling.

## Acceptance Criteria Before Implementation

- A small research fixture proves diamond propagation without duplicate
  recomputation.
- Stabilization recomputes necessary stale nodes at most once in deterministic
  topological or height order.
- Dynamic dependency changes through `bind` detach old dependencies.
- Dynamic dependency changes invalidate old selector scopes and do not recompute
  obsolete inner nodes.
- Node creation during stabilization respects current scope or fails with a
  typed graph error when scope is ambiguous.
- Scope save/restore is not exposed in the main public surface.
- Derived nodes have no public delete; observer disposal and bind-scope
  invalidation remove demand and stop recomputation.
- Cutoffs suppress downstream recomputation and observer callbacks.
- Default cutoff is physical equality; structural/domain equality is explicit
  opt-in per node or observer.
- Node equality controls downstream propagation; observer equality controls only
  that observer's callback emission.
- Equality callback exceptions are defects and do not publish partial pure
  snapshots.
- Observer registration does not run callbacks; the next stabilization emits the
  initialization event.
- Observer handles control demand and disposal; observation is not callback-only.
- Primary observer reads are Eta effects that expose initialized stabilized
  values and report invalid observer state through Eta failure semantics.
- Unsafe synchronous observer reads are limited to tests/debugging.
- Explicit observer disposal releases demand; finalizer cleanup is best-effort
  only and not required for correctness.
- Observer ordering and fail-fast behavior are typed and deterministic.
- Pure snapshot publication is atomic, but already-run observer effects are not
  rolled back on later failure.
- Multiple functor instances cannot compose signals by accident.
- The main public surface has no first-class graph values.
- Manual stabilization coalesces multiple source updates.
- Public source mutation from observer/effect phase stabilization work is
  delayed to the next stabilization.
- There is no public batch primitive; repeated mutations before one
  stabilization are the batch.
- Graph mutation, lifecycle changes, timer updates, and stabilization are
  serialized per graph while observer-handle reads do not mutate the graph.
- Signal graph instances and streams returned by `Stream.observe` are
  same-domain resources; they are not portable cross-domain handoff channels.
- Raw derived signals have no public value read; initialized observer handles
  are the derived value-read surface.
- Interruption of queued or active graph-lane work cleans up without leaving
  pending mutations behind.
- Reentrant stabilization and same-variable effectful update fail with typed
  graph errors.
- Cycle detection fails with a typed graph error.
- Public expected failures use small operation-scoped typed error families with
  clear pretty-printers, not generic exceptions or one catch-all variant.
- User callback exceptions fail the current operation as defects without
  permanently poisoning the graph; later stabilization may retry.
- Stats and debug introspection expose demand/recompute/scope behavior without
  mutating the graph.
- Signal-to-stream bridge emits observer updates after stabilization; the kernel
  does not include stream-to-signal policy.
- Lossy signal-to-stream bridge overflow is observable through graph stats and
  a drop hook.
- No public expert/custom-node surface bypasses graph invariants.
- Time/clock nodes use Eta runtime clock/sleep/schedule/test-clock primitives
  and do not run observer callbacks outside explicit stabilization.
- Eta runtime clock reads and sleeps share one monotonic time base; public time
  APIs do not interpret deadlines as wall-clock/civil timestamps.
- Time/clock nodes mark sources stale but do not call stabilization from the
  kernel.
- Time/clock nodes start work only while necessary and stop or become inert when
  unnecessary.
- Timer work is owned by graph demand and does not keep unnecessary subgraphs
  alive.
- A microbenchmark compares update/stabilization cost against manual
  `Mutable_ref` recomputation for representative static and dynamic graphs.

## Implementation Self-Audit Evidence

This section records current implementation evidence for the PRD audit. The
self-audit decisions reviewed on 2026-06-27 are incorporated into the final
contract and summarized in the review resolution below.

- Package boundary evidence: `dune-project`, `eta_signal.opam`, and
  `lib/signal/dune` define `eta_signal` as an optional public package/library
  depending on `eta` and `eta_stream`; the root `eta` package does not depend on
  `eta_signal`.
- Public surface evidence: `lib/signal/eta_signal.mli` exposes a functorized
  graph instance `Make(Observer_error)()` with opaque variable, signal, and
  observer types; explicit `stabilize`; source mutation and effectful update;
  observer lifecycle and reads; `const`, `map`, `map2` through `map9`, `both`,
  `all`, and `bind`; operation-scoped error families and pretty-printers; stats
  and DOT introspection; time nodes; and the signal-to-stream bridge.
- Public non-goal evidence: compile-negative fixtures under
  `test/signal/negative/` enforce no global graph, no accidental cross-graph
  signal composition, no first-class `Graph` surface, no raw derived signal
  read, no derived-signal dispose, no public batch primitive, no public
  `Expert`, no public `Scope`, no stream-to-signal bridge, no Solid-style
  `computed`, and no `map10` surface beyond the PRD's `map2` through `map9`
  target.
- Runtime acceptance evidence: `test/signal/test_eta_signal.ml` covers diamond
  propagation, deterministic recompute order, n-ary combinators, cutoffs,
  observer initialization/change/read/disposal semantics, disposal before
  initialization, same-stabilization observer disposal event-list behavior,
  observer ordering, fail-fast behavior, and observer reads after callback
  failure, delayed observer mutation, atomic pure snapshot rollback/retry,
  dynamic `bind` dependency detachment, scope invalidation, bind rollback, cycle
  detection, necessary-only recomputation, typed error
  pretty-printers, reentrant stabilization,
  same-variable effectful update reentry and in-flight conflict, queued and
  active graph-lane interruption cleanup, observer-effect interruption cleanup,
  stats/DOT introspection, time-node demand and explicit stabilization behavior,
  time-node refresh when observed after idle time, timer inertness after
  disposal or bind invalidation, dynamic timer activation refresh timing, timer
  restart after re-observation, timer callback daemon diagnostics, and
  signal-to-stream emission, closure, validation, equality suppression,
  bounded overflow dropping, and disposal while full.
- Benchmark evidence: `lib/signal/bench/bench_signal.ml` compares Eta signal
  update/stabilization cost against manual `Mutable_ref` recomputation for both
  representative static and dynamic graphs.

### Acceptance Criteria Evidence Matrix

This matrix is the current self-audit ledger for the acceptance criteria above.
All listed criteria have executable or manifest evidence. Decisions raised
during self-audit were reviewed on 2026-06-27 and are now part of the PRD
contract.

| Criterion | Current evidence | Audit status |
| --- | --- | --- |
| Diamond propagation without duplicate recomputation | `test_diamond_recomputes_shared_node_once` | Covered |
| Necessary stale nodes recompute at most once in deterministic topological order | `test_diamond_recomputes_shared_node_once`, `test_recompute_order_is_topological` | Covered |
| `bind` dynamic dependency changes detach old dependencies | `test_bind_detaches_old_dependency` | Covered |
| `bind` invalidates old selector scopes without recomputing obsolete inner nodes | `test_bind_invalidates_old_scope_without_recomputing_obsolete_nodes` | Covered |
| Node creation during stabilization respects scope or fails typed when ambiguous | `test_ambiguous_node_creation_during_pure_recompute_is_typed_failure`, `test_ambiguous_node_creation_during_observer_callback_is_typed_failure` | Covered |
| Scope save/restore is not public | `test/signal/negative/public_scope_negative.ml`, `lib/signal/eta_signal.mli` | Covered |
| Derived nodes have no public delete; disposal and bind invalidation remove demand | `test/signal/negative/derived_signal_delete_negative.ml`, `test_dispose_removes_demand`, `test_bind_invalidates_old_scope_without_recomputing_obsolete_nodes` | Covered |
| Cutoffs suppress downstream recomputation and observer callbacks | `test_cutoff_suppresses_downstream_recompute`, `test_observer_equality_suppresses_only_that_observer` | Covered |
| Default cutoff is physical equality; structural/domain equality is opt-in | `test_default_cutoff_is_physical_equality`, `test_source_equality_suppresses_graph_propagation`, `test_observer_equality_suppresses_only_that_observer` | Covered |
| Node equality controls propagation; observer equality controls only callback emission | `test_source_equality_suppresses_graph_propagation`, `test_cutoff_suppresses_downstream_recompute`, `test_observer_equality_suppresses_only_that_observer` | Covered |
| Equality callback exceptions are defects without partial pure snapshots | `test_cutoff_exception_is_defect_without_partial_snapshot`, `test_source_equality_exception_is_defect_without_partial_snapshot`, `test_observer_equality_exception_is_defect_without_partial_snapshot` | Covered |
| Observer registration does not run callbacks; next stabilization initializes | `test_observer_initializes_on_stabilize` | Covered |
| Observer handles control demand and disposal; observation is not callback-only | `lib/signal/eta_signal.mli`, `test_dispose_removes_demand`, `test_stats_and_dot_are_read_only` | Covered |
| Primary observer reads are Eta effects with typed invalid-state failures | `test_observer_initializes_on_stabilize`, `test_failed_initial_stabilization_leaves_no_current_value`, `test_dispose_removes_demand` | Covered |
| Unsafe synchronous observer reads are limited to tests/debugging | `lib/signal/eta_signal.mli`, `test_observer_unsafe_read_exn_reports_invalid_state` | Covered |
| Explicit observer disposal releases demand; correctness does not rely on finalizers | `test_dispose_removes_demand`, `test_dispose_before_initialization_removes_demand`, `test_observer_dispose_during_callback_keeps_collected_event`, `test_stats_and_dot_are_read_only` | Covered |
| Observer ordering, fail-fast behavior, and observer-effect interruption are deterministic | `test_observer_callbacks_run_in_registration_order`, `test_observer_failure_fails_stabilize`, `test_observer_failure_is_fail_fast`, `test_observer_callback_interruption_releases_phase` | Covered |
| Pure snapshot publication is atomic; already-run observer effects are not rolled back | `test_pure_failure_does_not_publish_partial_snapshot_and_can_retry`, `test_observer_failure_is_fail_fast`, `test_observer_effects_before_later_failure_are_not_rolled_back`, `test_observer_callback_construction_defect_does_not_poison_graph` | Covered |
| Multiple functor instances cannot compose signals by accident | `test_functor_instances_stabilize_independently`, `test/signal/negative/cross_graph_signal_negative.ml` | Covered |
| Main public surface has no first-class graph values | `test/signal/negative/first_class_graph_negative.ml`, `lib/signal/eta_signal.mli` | Covered |
| Manual stabilization coalesces multiple source updates | `test_manual_stabilization_coalesces_sets` | Covered |
| Public source mutation from observer/effect phase stabilization work is delayed to the next stabilization | `test_observer_mutation_is_delayed_to_next_stabilization` | Covered |
| There is no public batch primitive | `test/signal/negative/public_batch_negative.ml` | Covered |
| Graph mutation, lifecycle changes, timer updates, and stabilization are serialized while observer reads are non-mutating | `test_reentrant_stabilization_is_typed_failure`, `test_effectful_update_reentry_fails_and_preserves_value`, `test_queued_graph_operation_cancellation_does_not_run`, `test_active_graph_operation_interruption_releases_lane`, `test_observer_read_does_not_force_recompute` | Covered |
| Raw derived signals have no public value read | `test/signal/negative/raw_signal_read_negative.ml`, `test_observer_read_does_not_force_recompute` | Covered |
| Queued or active graph-lane interruption cleans up without pending mutations | `test_queued_graph_operation_cancellation_does_not_run`, `test_active_graph_operation_interruption_releases_lane`, `test_effectful_update_interruption_preserves_value_and_releases_slot` | Covered |
| Reentrant stabilization and same-variable effectful update fail typed | `test_reentrant_stabilization_is_typed_failure`, `test_reentrant_stabilization_does_not_clear_outer_phase`, `test_effectful_update_reentry_fails_and_preserves_value`, `test_concurrent_effectful_update_same_variable_fails_fast` | Covered |
| Cycle detection fails typed | `test_bind_cycle_detection_is_typed_failure` | Covered |
| Expected public failures use small operation-scoped typed error families with clear printers | `lib/signal/eta_signal.mli`, `test_error_pretty_printers_are_clear` | Covered |
| User callback exceptions are defects and do not permanently poison the graph | `test_pure_failure_does_not_publish_partial_snapshot_and_can_retry`, `test_observer_callback_construction_defect_does_not_poison_graph` | Covered |
| Stats and debug introspection expose demand/recompute/scope behavior without mutating | `test_stats_and_dot_are_read_only` | Covered |
| Signal-to-stream emits observer updates after stabilization; no stream-to-signal kernel policy | `test_stream_bridge_emits_after_stabilize`, `test_stream_bridge_closes_on_observer_dispose`, `test_stream_bridge_take_does_not_dispose_observer`, `test_stream_bridge_equal_suppresses_updates`, `test_stream_bridge_full_queue_does_not_block`, `test_stream_bridge_drop_callback_reports_loss`, `test_stream_bridge_full_queue_dispose_closes_without_waiting`, `test/signal/negative/stream_to_signal_negative.ml` | Covered |
| No public expert/custom-node surface bypasses graph invariants | `test/signal/negative/public_expert_negative.ml`, `lib/signal/eta_signal.mli` | Covered |
| Time/clock nodes use Eta runtime clock/sleep/schedule/test-clock primitives and do not run callbacks outside explicit stabilization | `lib/signal/eta_signal.ml`, `test_time_now_uses_runtime_clock`, `test_time_now_refreshes_after_idle_observe`, `test_time_interval_requires_explicit_stabilization` | Covered |
| Time/clock nodes mark sources stale but do not call stabilization from the kernel | `test_time_interval_requires_explicit_stabilization`, `test_time_after_deadline`, `test_time_after_elapsed_before_observe`, `test_time_absolute_deadline` | Covered |
| Time/clock nodes start only while necessary and stop or become inert when unnecessary | `test_time_interval_starts_only_when_observed`, `test_time_now_refreshes_after_idle_observe`, `test_time_timer_becomes_inert_after_dispose`, `test_time_interval_restarts_after_reobserve`, `test_time_timer_becomes_inert_after_bind_switch`, `test_time_now_bind_activation_refreshes_next_stabilization`, `test_time_step_defect_logs_daemon_diagnostic_and_restarts` | Covered |
| Timer work is owned by graph demand and does not keep unnecessary subgraphs alive | `test_time_timer_becomes_inert_after_dispose`, `test_time_interval_restarts_after_reobserve`, `test_time_timer_becomes_inert_after_bind_switch`, `test_stats_and_dot_are_read_only` | Covered |
| Microbenchmark compares signal update/stabilization with manual `Mutable_ref` recomputation for static and dynamic graphs | `lib/signal/bench/bench_signal.ml` | Covered |

- Current audit result: the implementation has executable or manifest evidence
  for the PRD acceptance criteria, and all self-audit decisions have been folded
  into the final contract text.

## Review Resolution

The self-audit decisions were reviewed on 2026-06-27 and are now part of this
PRD contract:

- Observer callback failures use the graph-wide observer error module and surface
  as `` `Observer_error`` from `stabilize`.
- The graph functor remains generative; repeated applications with the same
  observer error module still produce incompatible graph-owned types.
- Observer events are collected before observer callbacks run, so disposal
  during one callback does not cancel another already-collected event in the same
  stabilization.
- Runtime-clock-backed time constructors are effectful, use explicit `~every`
  cadence arguments, and own timers through graph demand.
- Time internals may use Eta `Schedule`, but v1 exposes no public
  schedule-taking time-node constructor.
- Timers made necessary by a `bind` branch switch during stabilization refresh
  after observer events for that snapshot, so the refreshed timer source appears
  on the next explicit stabilization.
- `Time.step` callback defects are timer-daemon diagnostics, not `stabilize`
  failures, and failed daemons clean up so later demand refresh can restart them.
- Node constructors stay synchronous so `bind` selectors can return signals
  directly; ambiguous construction is reported at the enclosing operation
  boundary.
- A second same-variable `update_effect` while one is active fails with
  `` `Reentrant_update`` instead of queueing.
- Public Eta mutations from the observer/effect phase during stabilization are
  delayed to the next stabilization; pure recompute functions remain synchronous
  and cannot mutate through Eta effects.
- `Stream.observe ?capacity` returns the observer lifecycle handle and stream,
  defaults capacity to 1024, drops newest stream updates when its bounded queue
  is full, closes on observer disposal after buffered updates drain, and does
  not dispose the observer when consumers stop early. The returned stream
  inherits the graph's same-domain restriction.

No unresolved implementation audit notes remain.
