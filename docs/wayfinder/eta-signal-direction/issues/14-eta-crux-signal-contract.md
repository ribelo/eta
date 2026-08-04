# Eta Crux Signal contract

Type: grilling
Status: resolved
Blocked by: 08, 12, 13

## Question

What exact contract does Eta Crux require from Eta Signal and Eta Signal Map?

Reconcile the graph-neutral computation design, the plain-state V1 design, and
the private incremental-engine direction. Include keyed `assoc`, dynamic
lifetime, timer wake information, stabilization, typed output, and test seams.

Use the active SecondAgent implementation as evidence. Do not preserve its
current shape only because implementation has started. Update or replace every
affected Eta Crux design decision in the answer.

## Answer

**Status: resolved.**

Eta Crux keeps one graph-neutral computation type. Each root interprets one
immutable description through one private Eta Signal graph.

Applications receive no Signal module, signal value, observer, graph, scope,
transaction, stabilization, or package endpoint.

The current custom Crux graph is implementation evidence, not the target engine.
It is replaced rather than wrapped.

## Public computation algebra

Eta Crux owns a graph-neutral cutoff type:

```ocaml
module Cutoff : sig
  type 'a t

  val always : 'a t
  val never : 'a t
  val phys_equal : 'a t
  val of_equal : ('a -> 'a -> bool) -> 'a t
  val of_compare : ('a -> 'a -> int) -> 'a t
end

type 'a t
type never = |

val return : 'a -> 'a t
val map : 'a t -> f:('a -> 'b) -> 'b t
val both : 'a t -> 'b t -> ('a * 'b) t
val cutoff : 'a t -> cutoff:'a Cutoff.t -> 'a t
val bind : 'a t -> f:('a -> 'b t) -> 'b t
```

A Crux cutoff has the same published-candidate direction as Signal Cutoff. The
private interpreter translates it without exposing the Signal type.

Descriptions are inert and reusable. Each allocating constructor owns one stable
description-node identity.

One live cell identity is:

```text
(root incarnation, structural scope incarnation, description-node identity)
```

Reuse of one allocating description in one scope shares one cell. Two constructor
calls or two roots create independent cells.

## State machines and actions

The exact state constructor is:

```ocaml
module State_machine : sig
  val create :
    ?model_cutoff:'model Cutoff.t ->
    ?diagnostics:('model, 'action) Diagnostic.state_machine ->
    'input t ->
    default_model:'model ->
    apply_action:
      (self:'action Endpoint.t ->
       input:'input ->
       model:'model ->
       action:'action ->
       'model * (unit, never) Eta.Effect.t) ->
    ('model * 'action Endpoint.t) t
end
```

Each live state machine owns one private Signal variable for its model. Its
committed frame stores the current input, model, endpoint incarnation, and model
variable.

Advancement validates the endpoint against the committed frame. It invokes
`apply_action` once with committed input and model.

The next model is staged through `Signal.Var.set`. The returned Eta effect stays
dormant in the active advancement.

One Signal stabilization privately commits the model, derived graph, dynamic
scopes, keyed scopes, and candidate root frame.

A transition failure stages nothing. A pre-commit Signal failure preserves the
previous frame and starts no effect.

The pending Signal candidate becomes unreachable after a fatal failed
advancement. Eta Crux never retries the consumed action.

## Committed root frame

The private root signal publishes one immutable frame:

```ocaml
type 'output frame = {
  output : 'output;
  endpoints : endpoint_manifest;
  lifecycle : lifecycle_manifest;
  sources : source_manifest;
}
```

The concrete manifest types stay private. They contain stable identities and
post-commit descriptions, not active effect bodies.

The root frame is the sole truth for endpoint validity and structural lifetime.
Crux keeps no separately committed mutable endpoint registry.

Endpoint admission and advancement consult the current frame under the root
lock. A removed endpoint becomes stale at the same publication point as its
removed component.

The final frame node uses `Eta_signal.Cutoff.never`. Each successful start or
action publishes one complete frame, even when public output compares equal.

### Private and public publication

Signal snapshot commit is private preparation. It is not the Eta Crux semantic
publication point.

At advancement start, Eta Crux takes the root lock, selects one event, records
the prior root-frame generation, and changes the phase to `Advancing`. It then
releases the lock.

Signal update, stabilization, and observer read run without the root lock. No
Crux API can read the private Signal snapshot.

After observer read, Crux constructs and validates one immutable root commit. It
contains the frame pointer, manifest differences, eligible transition effect,
and complete post-commit plan.

Crux then takes the root lock again. It verifies the `Advancing` phase, prior
generation, and fatal latch. One pointer assignment installs the root commit.

That pointer assignment is the Eta Crux semantic commit. Endpoint validation,
export availability, driver output, and later advancement read only this pointer
under the root lock.

No effect boundary, callback, allocation, or validation occurs while the pointer
is installed. The lock is released before output delivery or token start.

If failure occurs before pointer installation, the prior Crux frame remains
current. A privately committed Signal candidate becomes unreachable during fatal
root teardown.

If a defect occurs after pointer installation, rollback is unavailable. Eta Crux
crashes the root before output delivery and permits no later application
advancement.

## Root interpretation

Each root creates:

1. one `Eta_signal.Make` graph
2. one `Eta_signal_map.Make(Signal.Package)` adapter
3. one compiled root-frame signal
4. one private output observer without an update callback

The compiler maps graph-neutral descriptions as follows:

| Crux description | Private Signal interpretation |
|---|---|
| `return` | `Signal.const` |
| `map` | `Signal.map` |
| `both` | one direct `Signal.map2` |
| `cutoff` | translated `Eta_signal.Cutoff.t` |
| `bind` | `Signal.bind` with one fresh Crux compilation scope |
| state machine model | private `Signal.Var` |
| `Assoc(Order).assoc` | `Signal_map.Keyed(Order).mapi` |
| root frame | final node with `Eta_signal.Cutoff.never` |

The private output observer owns demand. It has no update or finish callback.
Crux calls `Observer.read` only after successful stabilization.

Signal callbacks never drive a host adapter. Driver output remains the only host
observation path.

## Advancement

Signal stabilization is effectful. `Root.advance` therefore becomes effectful:

```ocaml
val advance :
  'output Root.t ->
  (('output Root.outcome, Root.advance_error) result, never) Eta.Effect.t
```

`Root.create` stays synchronous. The internal `Start` advancement creates and
initializes the private graph.

One non-idle advancement follows this order:

1. Select one control event or one FIFO application message.
2. Validate endpoint incarnation against the committed frame.
3. Run one transition and stage its model and dormant effect.
4. Run one Signal stabilization.
5. Read the private candidate frame.
6. Build and validate one immutable root commit.
7. Install its pointer under the root lock.
8. Return the complete output and mandatory post-commit token.
9. Let the driver deliver output before it starts the token.

`Idle` runs no stabilization. Messages admitted during advancement wait for a
later advancement.

Signal graph failures become the existing fatal `Failed` outcome and mandatory
crash token. Signal defects retain their cause and backtrace in `Failure.t`.

Crux-owned manifest planning after frame read is pure and total. An internal
defect after private Signal commit crashes the root before output delivery.

No later application advancement occurs after that crash. The private graph is
not observable outside root teardown.

## Keyed assoc

The old `Map.S` and `data_equal` surface is deleted. The exact contract is:

```ocaml
module Assoc
    (Order : Eta_signal_map.Map.Ordered_type) : sig
  val assoc :
    ?data_cutoff:'data Cutoff.t ->
    'data Eta_signal_map.Map.Make(Order).t t ->
    f:(key:Order.t -> data:'data t -> 'output t) ->
    'output Eta_signal_map.Map.Make(Order).t t
end
```

`Order.compare = 0` defines key identity. The direct persistent map type defines
input and output order.

Continuous presence preserves the key representative, keyed scope, data source,
child graph, model, and endpoint incarnation.

Accepted same-key data changes update the stable child data in the same
stabilization. They do not rebuild the child.

Removal disposes the child incarnation. Same-key re-entry creates fresh state
and endpoints. Old queued actions remain stale.

Signal Map owns removal-before-addition, rollback, persistent output patches,
and change-proportional reconciliation.

## Dynamic lifetime and post-commit work

`bind` and `Assoc` determine structural presence inside the private graph. The
committed frame reflects only the final committed structure.

Eta Crux compares the previous and current manifests after stabilization. The
result becomes the mandatory post-commit token.

The driver delivers output first. Token start then requests removed-subtree
cancellation, opens new sources, and releases the transition effect.

Lifecycle and source effects never run during Signal planning, commit, or root
frame publication.

Eta owns fibers, resources, cancellation, supervision, and causes. Eta Crux owns
structural work membership and admission order.

## Source and time

`Source.create` changes `spec_equal` to a graph-neutral named cutoff:

```ocaml
val Source.create :
  spec_cutoff:'spec Cutoff.t ->
  spec:'spec t ->
  producer:('spec -> ('item, 'error) Source.producer) t ->
  target:'action Endpoint.t t ->
  on_item:('item -> 'action) t ->
  on_terminal:('error Source.terminal -> 'action) t ->
  unit t
```

Eta Crux V1 exposes no Signal time description. Timers use ordinary Eta effects
or `Source` producers and send typed endpoint actions.

The empty-to-nonempty ingress transition wakes the driver. Crux needs no Signal
timer wake hook, deadline query, or diagnostics poll.

A future Crux time description needs a separate contract with an explicit driver
wake law.

## Package boundary

The final dependencies are:

```text
eta_crux -> eta, eta_observability
eta_crux -> eta_signal (= same release)
eta_crux -> eta_signal_map (= same release)
eta_crux_test -> eta_crux, eta, eta_test
```

`eta_crux` has no direct `eta_stream` dependency. A stream-backed source adapter
belongs outside Crux core.

The root `eta`, `eta_signal`, and `eta_signal_map` packages never depend on Eta
Crux. Eta Crux uses only their public interfaces.

## Test boundary

`eta_crux_test` remains a thin harness over production `Root` and `Driver`.
Public tests advance one event, start its token, inspect complete output, inject
through delivered endpoints, and control sources.

Public tests receive no Signal graph, node, scope, observer, stabilization, or
work-counter handle.

Repository-private tests verify one graph and one output observer per root, one
stabilization per non-idle advancement, no stabilization on idle, state rollback,
bind and keyed identity, stale endpoints, and empty fiber census after teardown.

## Current implementation disposition

The current implementation confirms graph-neutral call sites, the public driver,
wire behavior, failures, requests, sources, and test-harness shape.

It does not instantiate `Eta_signal.Make`. It owns a custom dependency graph and
uses the stale `Eta_signal.Owner_transaction` and `Eta_signal_map.Keyed_map`
paths.

Delete that engine path. Do not retain it as a backend, fallback, or compatibility
mode.

## Alternatives rejected

### Public or restricted Signal modules

Even a restricted graph module makes every reusable component a functor. It
exposes an implementation fact without giving applications safe stabilization or
observation authority.

A full Signal module also permits independent variables, observers, and
stabilization. That breaks root ownership.

### Crux-owned snapshot engine

A prospective immutable snapshot can preserve the current public Crux behavior.
It also duplicates Signal scheduling, dynamic scopes, keyed lifetime, cutoff,
and transaction machinery.

The current implementation proves viability, not product value. Keeping it makes
Eta maintain two incremental engines.

### A second Signal transaction API

Eta Crux needs no public owner transaction or Crux-specific Signal node kind.
Model variables and one committed root frame place the atomic boundary inside the
existing Signal contract.

## Evidence

- `lib/crux/eta_crux.mli:1-86,400-434` shows the graph-neutral public shape and
  stale cutoff, assoc, source, and synchronous-advance APIs.
- `lib/crux/crux_graph_base.ml:97-179` shows the custom graph, scopes, endpoints,
  versions, and old owner transaction.
- `lib/crux/crux_assoc.ml:1-107` shows the custom keyed interpreter and stale
  `Keyed_map` path.
- `lib/crux/dune:1-5` records the current Signal dependencies.
- [Ticket 09](09-transaction-and-invalidation-model.md#answer) defines private
  atomic stabilization.
- [Ticket 12](12-engine-and-package-seams.md#answer) defines one graph factory and
  package adaptation.
- [Ticket 13](13-public-signal-algebra.md#answer) defines named cutoffs, optional
  observer callbacks, and effectful stabilization.
- [Eta Crux V1 design](../../../design/eta-crux-v1/README.md) is the authoritative
  Crux contract updated by this ticket.

## Census rows resolved here

Ticket 14 owns no claim-census rows. Its traceability comes from the existing
commitment matrix and the authoritative Eta Crux V1 design.

### Resolution spans

| Census ID | Resolution span |
|---|---|

## Implementation consequences

1. Keep the graph-neutral public description type and delete the custom engine.
2. Compile one description into one private Signal graph per root.
3. Move models to private Signal variables and publish one complete root frame.
4. Make `Root.advance` an Eta effect and run one stabilization per non-idle event.
5. Replace Crux equality callbacks with graph-neutral named cutoffs.
6. Replace `Assoc(Map.S)` and `Keyed_map` with `Assoc(Order)` and `Keyed.mapi`.
7. Keep timers as endpoint-producing Eta effects or sources.
8. Update exact package dependencies, production callers, and test harnesses.
9. Delete every custom-graph fallback and compatibility path.
