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

Source mutation during stabilization is allowed but delayed. It behaves as if
the mutation happened immediately after the current stabilization completes, so
the new source value is not visible to derived nodes or observers until the
next explicit stabilization.

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

Observer registration may also accept custom equality. Observer equality
controls callback emission for that observer only; it does not change the
observed signal's propagation behavior for other consumers.

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
- Source mutation during stabilization is delayed to the next stabilization.
- There is no public batch primitive; repeated mutations before one
  stabilization are the batch.
- Graph mutation, lifecycle changes, timer updates, and stabilization are
  serialized per graph while observer-handle reads do not mutate the graph.
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
- No public expert/custom-node surface bypasses graph invariants.
- Time/clock nodes use Eta runtime clock/sleep/schedule/test-clock primitives
  and do not run observer callbacks outside explicit stabilization.
- Time/clock nodes mark sources stale but do not call stabilization from the
  kernel.
- Time/clock nodes start work only while necessary and stop or become inert when
  unnecessary.
- Timer work is owned by graph demand and does not keep unnecessary subgraphs
  alive.
- A microbenchmark compares update/stabilization cost against manual
  `Mutable_ref` recomputation for representative static and dynamic graphs.

## Implementation Audit Notes

This section records implementation-time gaps or underspecified decisions that
need human review before the PRD is considered final.

- Observer callback typed errors needed a concrete OCaml surface. The
  implementation chooses a graph-wide observer error type as the graph functor
  parameter and wraps callback failures as `` `Observer_error`` from
  `stabilize`. The graph functor is a generative two-step functor,
  `Make(Observer_error)()`, so repeated applications with the same observer
  error module still create incompatible graph-owned signal/variable/observer
  types. The PRD should either bless that shape or specify a different callback
  error and graph-instance model.
- Time/clock nodes needed exact OCaml API signatures. The implementation
  chooses effectful constructors for runtime-clock-backed nodes, explicit
  `~every` intervals for current-time/deadline/relative-delay/step nodes, and
  demand-owned timer fibers that stop or become inert through observation
  disposal and dynamic-scope invalidation. The PRD should either bless that API
  shape or specify different signatures and lifecycle ownership.
- The time/clock acceptance text names Eta schedule primitives. The
  implementation currently uses runtime clock reads, `Duration`, `Effect.sleep`,
  runtime-managed daemon fibers, and the Eta test clock, but it does not expose
  or directly route timer nodes through a public `Schedule` API. The PRD should
  either bless sleep-loop-backed timer nodes as satisfying the schedule
  requirement, or specify a schedule-backed clock-node surface.
- Node constructors appear to need to stay synchronous/pure so `bind` selectors
  can return signals directly. The implementation reports ambiguous node
  creation during pure recomputation or observer callback construction through
  the typed `stabilize` error channel, but constructors themselves are not Eta
  effects. The PRD should either bless synchronous constructors with
  operation-boundary typed reporting, or specify a different constructor family
  if constructor-time typed failures outside effect-returning operations are
  required.
- Source mutation during stabilization needs phase-specific wording. The
  implementation supports ordinary source mutation from observer callbacks and
  other Eta effectful operations while the graph is in the observer/effect
  phase, and those mutations are delayed to the next explicit stabilization.
  Pure recomputation callbacks remain synchronous pure functions and do not
  receive an Eta effect context in which `Var.set` can be called normally. The
  PRD should either narrow the mutation-during-stabilization statement to
  effect-phase/public effect operations, or specify a safe effectful
  pure-recompute mutation mechanism.
- The signal-to-stream bridge needed a lifecycle and buffering contract. The
  implementation chooses `Stream.observe ?capacity` with a default capacity of
  1024, backed by an Eta queue with backpressure. Observer disposal cleanly
  closes the stream after buffered updates drain. Early stream termination does
  not dispose the observer; the returned observer remains the lifecycle handle.
  The PRD should either bless that shape or specify a different bridge
  ownership contract.
