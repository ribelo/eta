# PRD: eta_signal Incremental FRP Package

## Status

Draft. This PRD records the current grilling decisions for an optional
`eta_signal` package. It is not an implementation objective yet.

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
- Keep signal reads and derived values synchronous and ordinary OCaml values.
- Support explicit stabilization as the only core propagation mechanism.
- Support static derived nodes and explicit dynamic dependencies.
- Support deterministic effectful observers.
- Support per-node cutoffs to avoid unnecessary downstream propagation.
- Preserve OCaml-friendly graph ownership with functorized graph instances.

## Non-Goals

- No global ambient graph.
- No SolidJS-style implicit dependency tracking in the target contract.
- No automatic stabilization in the kernel.
- No UI framework, DOM model, TEA framework, or renderer.
- No STM.
- No cross-graph dependencies in the target contract.
- No direct dependency from root `eta` to `eta_signal`.
- No use of `eta_signal` from root `eta`; optional and higher-level Eta
  packages may use `eta_signal` after the package is proven.
- No JavaScript-specific performance assumptions as implementation proof.
- No promise that the target contract is as broad as Jane Street Incremental.

## Agreed Decisions

### Values and Effects

Signals carry ordinary OCaml values. Variables, signals, and observers are
distinct public concepts.

Reading a stabilized signal is synchronous. It returns the last stable cached
value directly, not an effect.

Operations that interact with graph state, observers, lifecycle, or runtime
behavior return Eta effects. This includes source mutation, stabilization,
observer registration/disposal, and effectful updates.

Computed nodes are pure and synchronous. Effectful work belongs in
observers or explicit update operations, not inside derived pure nodes.

### Explicit Stabilization

The kernel uses explicit stabilization. `set` marks sources dirty. It does not
propagate immediately and does not run observers.

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

Pure pull is not the target because `get` must remain a snapshot read rather
than a recomputation point. Eager push is not the target because it violates
manual batching and can compute intermediate states that no observer should
see. Alien Signals is useful implementation prior art for intrusive dependency
links and dirty flags, but its automatic JS-style effect scheduling is not the
semantic model for Eta.

### Reentrancy

Stabilization is non-reentrant. Calling stabilization while the same graph is
already stabilizing fails loudly as a defect instead of blocking, nesting, or
silently doing nothing.

Effectful update is non-reentrant per variable. Re-entering effectful update on
the same variable from inside its update callback fails loudly as a defect
instead of deadlocking. Updates to other variables still follow the normal
mutation rules.

Observer callbacks may call ordinary mutation operations. Those mutations mark
sources dirty for the next explicit stabilization; they do not mutate the
snapshot currently being observed.

### Functorized Graph Instances

The primary interface is a functorized graph instance. Each functor application
owns an independent graph.

The graph is not passed as a value to every constructor, and there is no hidden
global graph. This uses OCaml's module system for graph isolation.

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
intercepting `get`.

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

Invalid state should be unrepresentable where OCaml types can express the
constraint. When that is not possible, invalid graph states fail loudly instead
of being silently ignored.

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

`bind` is expected to be more expensive than `map`/`map2` and should be
documented as the graph-changing primitive.

Cycles are invalid and must fail loudly.

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
- `get` during observer callbacks still reads the snapshot produced by the
  current stabilization;
- disposal removes the observer from future stabilizations.

The target contract does not include an `Invalidated` update event. Observer
disposal is explicit and does not invoke callbacks.

### Liveness

Observers are the demand boundary. A signal becomes necessary when an observer
depends on it, directly or through derived nodes.

`stabilize` recomputes only the necessary dirty subgraph. Derived nodes with no
path to an observer are not recomputed during stabilization.

`get` reads the last stabilized cached value. It does not make the signal
necessary and does not force recomputation. If inputs have changed since the
last stabilization, `get` still returns the last stable snapshot.

### Cutoffs

The default cutoff is physical equality (`==`).

Nodes may accept custom equality:

Rationale:

- physical equality is cheap;
- structural equality can be expensive, raise, or be inappropriate for
  functions/custom values;
- consumers can opt into structural/domain equality where it is correct.

## Interface Shape

The surface is organized around a functorized graph module with opaque variable,
signal, and observer types.

The graph surface includes source creation and mutation, synchronous snapshot
reads, pure derived nodes, explicit dynamic dependencies, observer lifecycle,
and explicit stabilization.

The derived-node surface includes constants, watched variables, unary maps,
`map2` through `map9`, pairs, homogeneous collection joining, and explicit
dynamic binding. Derived nodes accept custom result cutoffs where useful.

## Open Questions

- Should `eta_stream` provide a `from_signal` bridge in the target contract, or
  should that wait until the kernel is proven?
- Should `eta_signal` expose graph statistics or debug inspection?

## Acceptance Criteria Before Implementation

- A small research fixture proves diamond propagation without duplicate
  recomputation.
- Stabilization recomputes necessary stale nodes at most once in deterministic
  topological or height order.
- Dynamic dependency changes through `bind` detach old dependencies.
- Dynamic dependency changes invalidate old selector scopes and do not recompute
  obsolete inner nodes.
- Cutoffs suppress downstream recomputation and observer callbacks.
- Observer registration does not run callbacks; the next stabilization emits the
  initialization event.
- Observer ordering and fail-fast behavior are typed and deterministic.
- Multiple functor instances cannot compose signals by accident.
- Manual stabilization coalesces multiple source updates.
- Reentrant stabilization and same-variable effectful update fail as defects.
- Cycle detection fails loudly.
- A microbenchmark compares update/stabilization cost against manual
  `Mutable_ref` recomputation for representative static and dynamic graphs.
