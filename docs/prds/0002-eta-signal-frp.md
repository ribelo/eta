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
- No SolidJS-style implicit dependency tracking in v1.
- No automatic stabilization in the kernel.
- No UI framework, DOM model, TEA framework, or renderer.
- No STM.
- No cross-graph dependencies in v1.
- No direct dependency from root `eta` to `eta_signal`.
- No JavaScript-specific performance assumptions as implementation proof.
- No promise that v1 is as broad as Jane Street Incremental.

## Agreed Decisions

### Values and Effects

Signals carry ordinary OCaml values:

```ocaml
type 'a signal
type 'a var
```

Reading a stabilized signal is synchronous:

```ocaml
val get : 'a signal -> 'a
```

Operations that interact with graph state, observers, lifecycle, or runtime
behavior return Eta effects:

```ocaml
val set : 'a var -> 'a -> (unit, 'err) Effect.t
val stabilize : unit -> (unit, 'err) Effect.t
val dispose : observer -> (unit, 'err) Effect.t
```

Computed nodes are pure and synchronous in v1. Effectful work belongs in
observers or explicit update operations, not inside derived pure nodes.

### Explicit Stabilization

The kernel uses explicit stabilization. `set` marks sources dirty. It does not
propagate immediately and does not run observers.

`stabilize` is the transaction boundary:

- recompute observed dirty graph in dependency order;
- apply cutoffs;
- update cached values;
- run observers whose observed values changed;
- return through `Effect.t`.

Automatic behavior can be built as an adapter that calls `stabilize` at chosen
loop boundaries. The core package must not assume a browser-like event loop.

### Functorized Graph Instances

The primary interface is a functorized graph instance:

```ocaml
module Make () : S
```

Each functor application owns an independent graph:

```ocaml
module Ui = Eta_signal.Make ()
module Config = Eta_signal.Make ()
```

The graph is not passed as a value to every constructor, and there is no hidden
global graph. This uses OCaml's module system for graph isolation.

### No Cross-Graph Dependencies

Values from different functor applications do not compose directly. One graph
is one stabilization domain.

Cross-graph data flow, if needed, is an explicit edge outside the kernel:
observe or read from one graph, then set a variable in another graph.

### Explicit Dependency Combinators

V1 is Incremental-like, not Solid-like. Dependencies are described by
combinators:

```ocaml
val const : 'a -> 'a signal
val watch : 'a var -> 'a signal
val map : ?equal:('b -> 'b -> bool) -> ('a -> 'b) -> 'a signal -> 'b signal
val map2 :
  ?equal:('c -> 'c -> bool) ->
  ('a -> 'b -> 'c) ->
  'a signal ->
  'b signal ->
  'c signal
val bind :
  ?equal:('b -> 'b -> bool) ->
  'a signal ->
  ('a -> 'b signal) ->
  'b signal
```

There is no v1 `computed : (unit -> 'a) -> 'a signal` that tracks dependencies
by intercepting `get`.

### Dynamic Dependencies

V1 includes explicit `bind` as the dynamic dependency primitive.

`bind source f` depends on `source`. When `source` changes and passes cutoff,
the node detaches from the old inner signal, attaches to the signal returned by
`f current`, and exposes that inner signal's current value.

`bind` is expected to be more expensive than `map`/`map2` and should be
documented as the graph-changing primitive.

Cycles are invalid and must fail loudly.

### Effectful Updates

V1 includes a single effectful update primitive:

```ocaml
val modify_effect :
  'a var ->
  ('a -> ('b * 'a, 'err) Effect.t) ->
  ('b, 'err) Effect.t
```

Semantics:

- updates to a variable are serialized;
- the callback sees the current value;
- on success, the new value is stored and published to the graph exactly once;
- on typed failure, defect, or interruption, the value is unchanged;
- cleanup releases the update slot.

Re-entering update on the same variable from inside `modify_effect` is invalid
or deadlocks depending on implementation. The final implementation must choose
one behavior and document it.

### Observers

V1 exposes explicit effectful observers:

```ocaml
type observer

val observe :
  ?equal:('a -> 'a -> bool) ->
  'a signal ->
  ('a -> (unit, 'err) Effect.t) ->
  (observer, 'err) Effect.t
```

Observer semantics:

- observers run only during `stabilize`;
- observers see stabilized values, not intermediate updates;
- observer callbacks run when the observed value changes by cutoff;
- observers run in deterministic registration order;
- typed observer failure makes `stabilize` fail;
- defects and interruption propagate normally;
- observers that already ran before a failure are not rolled back;
- observers after a fail-fast observer failure do not run;
- disposal removes the observer from future stabilizations.

### Cutoffs

The default cutoff is physical equality (`==`).

Nodes may accept custom equality:

```ocaml
val var : ?equal:('a -> 'a -> bool) -> 'a -> 'a var
val map : ?equal:('b -> 'b -> bool) -> ...
val observe : ?equal:('a -> 'a -> bool) -> ...
```

Rationale:

- physical equality is cheap;
- structural equality can be expensive, raise, or be inappropriate for
  functions/custom values;
- consumers can opt into structural/domain equality where it is correct.

## Sketch Interface

```ocaml
module type S = sig
  type 'a var
  type 'a signal
  type observer

  val var : ?equal:('a -> 'a -> bool) -> 'a -> 'a var
  val watch : 'a var -> 'a signal
  val const : 'a -> 'a signal

  val get : 'a signal -> 'a

  val set : 'a var -> 'a -> (unit, 'err) Effect.t
  val modify : 'a var -> ('a -> 'b * 'a) -> ('b, 'err) Effect.t
  val modify_effect :
    'a var ->
    ('a -> ('b * 'a, 'err) Effect.t) ->
    ('b, 'err) Effect.t

  val map :
    ?equal:('b -> 'b -> bool) ->
    ('a -> 'b) ->
    'a signal ->
    'b signal

  val map2 :
    ?equal:('c -> 'c -> bool) ->
    ('a -> 'b -> 'c) ->
    'a signal ->
    'b signal ->
    'c signal

  val bind :
    ?equal:('b -> 'b -> bool) ->
    'a signal ->
    ('a -> 'b signal) ->
    'b signal

  val observe :
    ?equal:('a -> 'a -> bool) ->
    'a signal ->
    ('a -> (unit, 'err) Effect.t) ->
    (observer, 'err) Effect.t

  val dispose : observer -> (unit, 'err) Effect.t
  val stabilize : unit -> (unit, 'err) Effect.t
end

module Make () : S
```

## Open Questions

- Should observers fire with the initial value on first `stabilize`, or only
  after a value changes?
- Are unobserved derived nodes recomputed during `stabilize`, or only nodes
  needed by observers and explicit reads?
- Should `get` on a dirty signal before stabilization return the last
  stabilized value, fail loudly, or force a local recomputation?
- Should `stabilize` process all dirty nodes before running any observers, or
  interleave recomputation and observers by topological order?
- Should observer callbacks be allowed to call `set`, and if so are those
  updates applied in the current stabilization or the next one?
- Should v1 include `map3`/`both`/`tuple` convenience helpers, or keep only
  `map`/`map2`/`bind`?
- Should `eta_stream` provide a `from_signal` bridge in v1, or should that wait
  until the kernel is proven?
- Should `eta_signal` expose graph statistics or debug inspection?

## Acceptance Criteria Before Implementation

- A small research fixture proves diamond propagation without duplicate
  recomputation.
- Dynamic dependency changes through `bind` detach old dependencies.
- Cutoffs suppress downstream recomputation and observer callbacks.
- Observer fail-fast behavior is typed and deterministic.
- Multiple functor instances cannot compose signals by accident.
- Manual stabilization coalesces multiple source updates.
- Cycle detection fails loudly.
- A microbenchmark compares update/stabilization cost against manual
  `Mutable_ref` recomputation for representative static and dynamic graphs.

