# Staged-effect observability

Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

What direct observation of staged transition effects belongs in Eta Crux tests?

Check whether tests can assert ordered staging, absence, start, interruption,
and settlement without waiting for downstream consequences. Compare:

- injected controlled dependencies.
- per-commit effect lifecycle observations.
- Eta-level effect observations.
- an inspectable command algebra.

Opaque Eta effects remain the default. Consider a command algebra only if opaque
effects cannot provide the required assertions without duplicated protocols.

Decide whether to adopt, defer with a precise condition, or reject each needed
observation. For accepted observations, specify identity, ordering, redaction,
API shape, laws, test controls, ownership, runtime cost, and migration effects.

## Answer

Adopt an optional, test-only observer for transition effects. The observer
records the effect lifecycle for each successful commit. It does not inspect
the effect value.

Keep controlled dependencies for typed calls and results. Reject Eta-level
events as a substitute for commit observation. Reject an inspectable command
algebra.

The evidence comes from the
[current baseline](../../../../.scratch/research/eta-crux-capability-audit/01-current-eta-crux-capability-baseline.md),
[Eta substrate audit](../../../../.scratch/research/eta-crux-capability-audit/06-eta-substrate-capability-support.md),
and
[consumer audit](../../../../.scratch/research/eta-crux-capability-audit/07-representative-consumer-friction.md).

Current tests use counters, promises, controlled calls, and polling loops.
These controls observe effect execution, but they do not observe commit
staging. They also cannot attribute overlapping effects to exact commits.

### Classification

| Mechanism | Decision | Reason |
|---|---|---|
| Per-commit transition-effect lifecycle | Adopt | Only Eta Crux knows the successful commit, structural owner, and post-commit admission point. |
| Injected controlled dependencies | Adopt as a complementary control | They provide typed input, completion, cancellation, and scheduler control after an effect starts. |
| Eta-level effect observations | Reject as the Crux staging surface | They observe execution, not committed staging or effects that never start. |
| Inspectable command algebra | Reject | Opaque effects plus lifecycle records provide every required assertion. |

No item is deferred.

### Explicit effect absence

Change the transition result from:

```ocaml
'model * (unit, never) Eta.Effect.t
```

to:

```ocaml
'model * (unit, never) Eta.Effect.t option
```

`None` means that the transition stages no effect. `Some effect` stages one
opaque effect.

This change removes the current physical-identity check against
`Eta.Effect.unit`. The observer must not expose that implementation detail.
This option is not a command wrapper or command algebra.

### Observation scope

The observer covers transition effects only. It does not cover lifecycle
programs, source openings, source producers, requests, or adapter work.

[Structural model reset](20-structural-model-reset.md) can stage zero or many
transition effects in one commit. An ordinary endpoint transition still stages
zero or one effect.

The observer is local to one root and one test. It is not operational
telemetry. No event crosses a local or serialized adapter boundary.

### API shape

`eta_crux_test` exposes this controller:

```ocaml
module Transition_effect_observer : sig
  module Effect_id : sig
    type t
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
  end

  module Commit_index : sig
    type t
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
    val to_int64 : t -> int64
  end

  module Event_position : sig
    type t
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
    val to_int64 : t -> int64
  end

  type settlement =
    | Succeeded
    | Interrupted
    | Failed

  type event =
    | Staged of {
        position : Event_position.t;
        commit : Commit_index.t;
        effects : Effect_id.t list;
      }
    | Started of {
        position : Event_position.t;
        effect : Effect_id.t;
      }
    | Settled of {
        position : Event_position.t;
        effect : Effect_id.t;
        settlement : settlement;
      }
    | Discarded_before_start of {
        position : Event_position.t;
        effect : Effect_id.t;
      }

  type t

  val create : unit -> t
  val attachment : t -> Eta_crux.Testing.transition_effect_observer
  val poll : t -> event option
  val drain : t -> event list
  val expect_empty : t -> unit
end
```

`Eta_crux.Testing` exposes only the attachment SPI and shared observation
types. `Eta_crux.Root.create` gains this optional argument:

```ocaml
?transition_effect_observer:Eta_crux.Testing.transition_effect_observer
```

The controller remains the supported user API. The SPI does not expose custom
callbacks.

One controller can attach to one root. A second attachment raises
`Invalid_argument`. The observer cannot detach, reset, or attach to another
root.

### Identity and lifecycle

Commit indices start at zero. Each successful commit consumes the next index.
Idle, rejected, stopped, and failed advancements do not consume an index.

Every successful commit records one `Staged` event. An empty `effects` list
proves that the commit staged no transition effect. Each list item introduces
one new effect identity.

Effect identities are opaque and root-local. They exist only when an attached
observer records them in `effects`. They expose no structural identity.

An ordinary endpoint transition contributes zero or one effect. A structural
reset contributes one effect for each reset callback that returns `Some effect`.
List order introduces observer identities only. It has no structural, callback,
start, or settlement meaning.

Event positions start at zero. Each recorded event consumes the next position.
Positions define the FIFO observation order.

`Started` means that Eta Crux registered the owned job and released its effect
to Eta. It does not mean that the Eta scheduler ran the first application
instruction.

`Settled` occurs after the effect and all its finalizers finish. An `Ok` exit
produces `Succeeded`. An interruption-only cause produces `Interrupted`. Every
other cause produces `Failed`.

`Discarded_before_start` means that a committed effect never entered the Eta
runtime. The event gives no reason. It covers owner disposal and terminal
replacement of a pending batch.

Each present effect follows exactly one path:

```text
Staged -> Started -> Settled
Staged -> Discarded_before_start
```

`Staged` precedes `Started` or `Discarded_before_start` for the same effect.
`Started` precedes `Settled`. Eta Crux gives no settlement-order guarantee
between different effects.

### Queue behavior

The controller uses one unbounded FIFO observation queue. Recording has no
backpressure and runs no user callback.

`poll` removes the next event. `drain` removes the current ordered snapshot.
Events from live effects can arrive after either operation returns.

`expect_empty` checks only for undrained events. It does not assert that all
observed effects settled. Root stop and the lifecycle events provide that
settlement evidence.

### Redaction

Events contain no effect name, blueprint description, action, model, output,
request, response, or cause. They contain no root, graph, cell, endpoint,
scope, fiber, or interruption identity.

Detailed failures remain in `Eta_crux.Failure`. Effect names, annotations,
spans, and runtime causes remain Eta observations.

### Laws and executable gates

The implementation effort adds these laws and named gates:

| Law | Gate |
|---|---|
| Every successful commit records exactly one `Staged` event with the next commit index. Its list exactly matches all optional transition effects from that commit. Generated commits cover empty, singleton, and multi-effect inventories. | `qcheck_transition_effect_observer_inventory` |
| Each present effect records exactly one terminal path. Generated cases cover success, interruption, failure, and discard before start. | `qcheck_transition_effect_observer_lifecycle` |
| Per-effect lifecycle order follows the two accepted paths. Generated overlapping effects include an observed out-of-order settlement. | `qcheck_transition_effect_observer_order` |
| `poll` and `drain` preserve event-position order and remove each returned event exactly once. | `qcheck_transition_effect_observer_fifo` |
| Adding the canonical observer changes no root output, failure, terminal result, admission result, or fiber settlement. | `qcheck_transition_effect_observer_transparency` |
| With no observer, committed actions allocate no observation IDs, events, or queue entries. Per-action allocation matches the current path. | `transition_effect_observer_disabled_allocation` |

The generated laws execute both sides of each comparison. Each failure prints
the generated commits and observed events. Tests with no valid background work
finish with an empty fiber census.

The disabled-path benchmark uses the existing disabled-telemetry threshold. It
requires equal per-action allocation and no more than a 5% median regression
in two of three comparisons.

### Ownership and cost

Eta Crux owns commit identity, effect identity, lifecycle classification, and
event order. `eta_crux_test` owns the controller, queue access, and assertion
helper.

Eta owns effect execution, scheduling, interruption, finalizers, controlled
dependencies, and runtime observations. Applications own their typed
dependencies and result actions.

Without an observer, event points perform only an attachment check. They
allocate no observation value or queue entry. The current empty-batch fast path
remains.

With an observer, each commit adds one `Staged` record and queue entry. Each
present effect adds a `Started` record and one terminal record. Concurrent
settlement uses the same observer-local queue.

### Migration

All `State_machine.create` callers move to `Some effect` or `None`. Observer
consumers move from one optional identity to the complete `effects` list. There
is no compatibility form and no silent conversion from `Eta.Effect.unit`.

Tests replace counters, promises, and polling only when they assert Eta
Crux-owned staging or lifecycle. Controlled dependencies remain for typed
values, completion control, and scheduler scenarios.

The implementation effort updates the public interfaces, semantic laws, law
registry, verification gates, and exclusion text together. Production callers
that do not attach an observer receive no new observation behavior.

This decision adds no new Wayfinder ticket. The accepted surface is complete
enough for the final capability reconciliation.
