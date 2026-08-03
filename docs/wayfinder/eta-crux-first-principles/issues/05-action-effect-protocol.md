# Action injection and staged Eta effects

Type: grilling
Status: resolved
Blocked by: 02

## Question

What is the exact state-machine protocol behind the agreed rule that a
synchronous transition can stage Eta effects through a restricted context?

Decide:

- the types of the model, action, response, injection function, and transition
  context.
- whether injection returns `unit Effect.t` or supports typed responses.
- whether staged effects can inject only into the current state machine or into
  any captured injector.
- when staged effects start relative to model commit and stabilization.
- effect ordering, concurrency, cancellation, and ownership.
- how typed failures become actions or responses.
- what happens when a transition raises or violates the context lifetime.
- whether simple setters are state machines with hidden actions or a separate
  primitive.

Keep Eta effects as ordinary Eta values. Do not add a command wrapper unless a
specific invariant cannot be expressed without one.

## Answer

### Core protocol

Eta Crux exposes a typed local destination, not an injection closure:

```ocaml
type never = |

module Endpoint : sig
  type 'message t
  type admission_error = Ingress_closed

  val send :
    'message t ->
    'message ->
    (unit, admission_error) Eta.Effect.t

  val contramap :
    'target t -> f:('source -> 'target) -> 'source t
end
```

An endpoint accepts repeated messages while its target incarnation remains
live. One-shot host responses use a separate request-resolution contract.
Rank-2 scope brands can prevent escape, but they cannot enforce one call.

`Endpoint.send endpoint message` builds an Eta effect. If the target root accepts
ingress, interpreting that effect appends the message and returns `Ok ()`. It
does not run the target transition or promise later processing.

If root closure wins the admission race, the effect returns
`Error Ingress_closed` and appends nothing. This result is an expected framework
failure, not interruption or a defect.

Endpoint incarnation validation happens during advancement. A stale message
returns `Rejected Stale_endpoint` from the later advancement. The send effect
returns no state-machine response.

[Failure, defect, and crash boundary](11-failure-boundary.md) defines atomic
closure arbitration and the complete root failure policy.

`Endpoint.contramap target ~f` creates a narrower endpoint. It shares the
target's identity, incarnation, and lifetime. It creates no state machine or
queue.

The semantic state-machine signature is:

```ocaml
module State_machine : sig
  val create :
    default_model:'model ->
    input:'input t ->
    apply_action:
      (self:'action Endpoint.t ->
       input:'input ->
       model:'model ->
       action:'action ->
       'model * (unit, never) Eta.Effect.t) ->
    ('model * 'action Endpoint.t) t
end
```

[OCaml API syntax and ergonomics](14-ocaml-api-ergonomics.md) owns the final
names and argument order.

### Transition laws

`apply_action` runs synchronously. It receives the current input, current model,
one action, and its own endpoint. It returns a new immutable model value and one
dormant Eta effect.

The returned effect can send through any endpoint received through explicit
composition. Possession of an endpoint grants typed sending authority. Eta Crux
provides no ambient endpoint lookup or global action bus.

Expected application-operation success and failure become later actions before
the returned effect finishes. The empty `never` error type enforces this rule.
Eta defects, interruption, and cleanup diagnostics remain outside that channel.

Endpoint admission is a framework operation. A returned effect handles
`Ingress_closed` explicitly before it becomes the typed-infallible staged
effect. This requirement prevents silent delivery loss across root lifetimes.

If `apply_action` raises, Eta Crux commits no model from that action and starts
no returned effect. The exception becomes a defect. This is stronger than
Bonsai's direct exception propagation because Bonsai context-scheduled work has
no rollback.

Simple state is a convenience over the same state machine. Its implementation
uses a hidden set action and does not add another storage primitive.

### Effect staging

The runtime records each returned effect with its source machine incarnation.
No effect becomes eligible before the complete advancement commits. A failed
advancement starts none of its effects.

A committed advancement returns the effect inside an opaque post-commit batch.
The driver delivers committed output before starting that batch. Effects from
different advancements can run concurrently. Completion order is unconstrained.
Each Eta effect defines its own internal sequencing and concurrency.

[Deterministic advancement transaction](06-advancement-transaction.md) defines
post-commit admission and prevents another advancement before batch start.

[Dynamic lifetime and work ownership](07-dynamic-lifetime-ownership.md) defines
cancellation after source disposal. [Failure, defect, and crash boundary](11-failure-boundary.md)
defines how effect defects and cleanup diagnostics reach drivers.

### Shell boundary

`Endpoint.t` contains no codec and no wire identifier. Internal action values
remain ordinary typed OCaml values.

An explicit shell export pairs a narrowed endpoint with its payload codec. A
local transport uses the typed endpoint directly. A serialized transport assigns
an opaque handle and retains the endpoint plus decoder in its core-side registry.

This keeps the application architecture independent of shell placement. It also
avoids remote-handle allocation and encoding on the local path. The new
[Exported endpoint and handle contract](16-exported-endpoint-contract.md) owns
the exact export API and lifecycle.

### Rejected alternatives

Eta Crux does not expose `'action -> unit Effect.t` as the destination type. It
does not add `Command.t`, a mutable staging context, or a global message bus.

State-machine endpoints have no one-shot cardinality parameter. A local endpoint
never carries a codec. It reports ingress admission but returns no application
response. Extra delegation wrappers add no authority beyond endpoint possession.
