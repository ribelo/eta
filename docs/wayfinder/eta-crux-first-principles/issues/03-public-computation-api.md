# Public computation and construction API

Type: prototype
Status: resolved
Blocked by: 02

## Question

What public OCaml API represents a typed changing computation while keeping
`eta_signal` private? The computation can allocate state, injection, lifecycle,
and child computations.

Produce small `.mli` sketches for the strongest candidates. Compare:

- one public `'a t` plus an explicit or threaded construction context.
- separate public value and structural-computation types.
- a single computation type that hides both distinctions.
- explicit graph arguments, generative modules, and rank-2 or first-class module
  encodings where they improve safety.

The sketch must show pure mapping, applicative composition, dynamic `bind`, one
state machine, one child computation, and root construction. Invalid
cross-application composition must fail in types. Application code must not see
raw signals, observers, stabilization, or private graph scopes.

Judge the candidates by call-site clarity, inferred types, error messages,
dynamic construction, and the amount of engine machinery exposed. Link the
prototype assets from the answer.

## Answer

### Decision

Eta Crux uses one global, graph-neutral type named `'a t`. A value of this type
is an immutable computation description. It is not a live signal or a running
application.

The public description algebra has this semantic core:

```ocaml
type 'a t
type never = |

module Endpoint : sig
  type 'message t

  val send : 'message t -> 'message -> (unit, never) Eta.Effect.t

  val contramap :
    'target t -> f:('source -> 'target) -> 'source t
end

val return : 'a -> 'a t
val map : 'a t -> f:('a -> 'b) -> 'b t
val both : 'a t -> 'b t -> ('a * 'b) t
val cutoff : 'a t -> equal:('a -> 'a -> bool) -> 'a t
val bind : 'a t -> f:('a -> 'b t) -> 'b t

val state_machine :
  ?equal:('model -> 'model -> bool) ->
  default_model:'model ->
  input:'input t ->
  apply_action:
    (self:'action Endpoint.t ->
     input:'input ->
     model:'model ->
     action:'action ->
     'model * (unit, never) Eta.Effect.t) ->
  ('model * 'action Endpoint.t) t

val lifecycle : (unit, never) Eta.Effect.t t -> unit t

module Root : sig
  type 'a description := 'a t
  type 'a t

  val create : 'a description -> 'a t
end
```

[Action injection and staged Eta effects](05-action-effect-protocol.md) defines
endpoint delivery. [Deterministic advancement transaction](06-advancement-transaction.md)
defines root advancement and observation.
[Dynamic lifetime and work ownership](07-dynamic-lifetime-ownership.md) defines
lifecycle programs and ownership. [OCaml API syntax and ergonomics](14-ocaml-api-ergonomics.md)
decides derived helpers and syntax.

Children are ordinary functions that return descriptions. Eta Crux does not
provide a pass-through `child` combinator.

### Identity and isolation

Each allocating constructor creates a stable description-node identity. A root
instantiates these nodes in one private `eta_signal` graph.

Reusing one description in one scope shares its state machine:

```ocaml
let counter = Counter.create () in
both counter counter
```

Two constructor calls create independent state machines:

```ocaml
both (Counter.create ()) (Counter.create ())
```

A live cell has three identity parts: the root, the dynamic or keyed scope, and
the description node. Thus, two roots have isolated state. Two keyed scopes can
also instantiate the same description as separate children. Ticket 04 refines
the keyed rule.

The original cross-application rule was too broad. Ordinary closures can carry
any OCaml value. The type rule covers live graph dependencies.

Description combinators never accept `Root.t`. Therefore, a live graph node
from one root cannot become a dependency of another root. Eta Crux does not
provide a root-to-description bridge.

This rule does not prohibit ordinary OCaml value capture. For example, a
description can contain a shared reference as data. Pure callbacks must not use
such values as hidden reactive dependencies.

### Comparison

The separate `Value.t` and `Computation.t` design makes allocation visible in
types. It also duplicates combinators and requires lifts between two algebras.
Inert descriptions provide the required construction safety with one interface.

A generative `Make ()` design rejects values from different module instances.
However, the brand identifies the module instance, not each root. Reusable
children also require functors or first-class modules.

A rank-2 builder rejects brand escape and supports ordinary reusable functions.
However, it exposes an application parameter and a construction capability.
The capability can also enter a callback closure. These costs do not provide
needed graph safety.

An explicit graph or scope argument exposes private engine machinery. It also
adds an argument to every structural constructor. The description interpreter
already owns this information.

### Bonsai functor history

Bonsai v0.13 exposed `Bonsai.Make (Incr) (Event)`. The functor let a host select
an Incremental instance and an event type. Bonsai removed this public functor in
June 2020 and bound the package to fixed UI Incremental and event modules.

This removal was not the Proc-to-Cont migration. Proc appeared in 2020. Cont
appeared in 2024 and is now the default. Current Cont uses one `'a t` and an
explicit `local_ graph` construction argument. Incremental itself still uses a
generative `Incremental.Make ()`.

The public sources do not state why Jane Street removed `Bonsai.Make`. Therefore,
Eta Crux does not use that removal as proof for either design. Engine
generativity and the public computation interface are separate decisions.

The Eta Crux decision remains unchanged. `Root.create` privately creates an
`eta_signal` graph for a graph-neutral description. This design permits isolated
roots without a public functor or graph capability.

The full source review records the timeline and the tradeoffs:
[bonsai-functor-history.md](../../../../.scratch/research/eta-crux/bonsai-functor-history.md).

### Prototype evidence

The selected prototype is on branch
`prototype/eta-crux-api-description-neutral` at commit `f30b9024`:

- [description-neutral prototype](https://github.com/ribelo/eta/tree/f30b9024/.scratch/prototypes/eta-crux-api/description-neutral)

Two rejected alternatives remain as comparison evidence:

- [separate value and computation types](https://github.com/ribelo/eta/tree/04d1822c/.scratch/prototypes/eta-crux-api/staged), branch `prototype/eta-crux-api-staged`, commit `04d1822c`.
- [rank-2 branded builder](https://github.com/ribelo/eta/tree/58544ba9/.scratch/prototypes/eta-crux-api/rank2-builder), branch `prototype/eta-crux-api-rank2`, commit `58544ba9`.

All three positive sketches compile in the repository Nix shell. Their negative
cases reject root or application mixing at compile time. The selected prototype
also rejects a `Root.t` value as an argument to `both`.
