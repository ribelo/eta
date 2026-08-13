# Alternative public interfaces

Type: grilling
Status: resolved
Blocked by: 06, 07

## Question

What radically different public interfaces can place this capability at a deep
Eta Crux seam?

Use Design It Twice with at least three independent interface designs. Compare
depth, locality, seam placement, caller work, adapter work, typed heterogeneity,
dynamic structure, codec registration, and transport equivalence.

The comparison must include complete root output, changed complete values,
notification followed by typed pull, independent streams, and application
publication through `Poll` and `Host_operation`.

Reject an alternative only for a semantic reason. Recommend an interface, but
do not select it for the user.

## Answer

Five interface designs were compared. Complete snapshot push, changed-value
batch push, and notification followed by typed pull are semantically eligible.
Independent streams and application publication are not eligible.

The user approved a common projection surface for the three eligible designs:

```ocaml
module Projection : sig
  module Kind : sig
    type ('key, 'value) t
    type packed = Pack : ('key, 'value) t -> packed

    val define :
      name:string ->
      key_compare:('key -> 'key -> int) ->
      key_codec:'key Codec.t ->
      value_codec:'value Codec.t ->
      cutoff:'value Cutoff.t ->
      ('key, 'value) t
  end

  module Schema : sig
    type t
    val create : Kind.packed list -> t
  end

  val publish :
    ('key, 'value) Kind.t ->
    key:'key ->
    'value Eta_crux.t ->
    'value Eta_crux.t
end

module Root : sig
  type t

  val create :
    schema:Projection.Schema.t ->
    ingress_capacity:int ->
    request_capacity:int ->
    _ Eta_crux.t ->
    t
end
```

Each `Projection.Kind.define` call creates a distinct kind. A kind owns its
wire name, key order, key codec, value codec, and value cutoff.

`Projection.Schema.create` fixes all kinds for one root. It rejects duplicate
wire names before root startup. The same schema applies to identity and
serialized transport.

`unit` is the key type for a singleton projection. Dynamic projections use
their domain key type.

`Projection.publish` is a structural occurrence. It returns the same typed
value that it publishes, so local computations can reuse that value.

`Root.t` has no output type parameter. `Root.create` accepts any computation
and does not publish its local result. A former shell-visible root result
becomes a named projection.

Eta Crux allocates a projection incarnation when an attachment commits.
Applications and transports do not allocate incarnations.

`Root.advance` returns an opaque `Projection.Commit.t` for a successful commit.
The commit contains the complete snapshot and its update batch. Each candidate
controls which part its public interface exposes.

Typed lookup by kind and key is the primary read interface. An existential fold
supports generic adapters and dynamic membership.

If one commit removes and reattaches one identity, typed batch lookup returns
`Removed` and then `Attached`. It does not combine or discard those updates.

### Complete projection snapshot push

This design makes one complete `Projection.Snapshot.t` the delivered root
value. The snapshot contains only active attachments. Each attachment contains
its identity, incarnation, and complete projection value.

Snapshot absence means that a projection is absent. An adapter compares the
snapshot with its latest delivered snapshot to find attachment, change,
removal, and incarnation restart.

The public commit interface exposes only the snapshot. The update batch remains
hidden. Session replacement delivers the current snapshot again.

Every successful commit requires one acknowledgment. This rule includes a
commit whose snapshot equals the preceding snapshot.

This interface has high depth and low caller work. It gives adapters the most
reconciliation work, but it keeps delivery as one complete value.

### Changed complete-value batch push

This design delivers:

```ocaml
type Projection.delivery =
  | Updates of Projection.Batch.t
  | Bootstrap of Projection.Snapshot.t
```

`Updates` belongs to one successful advancement. `Bootstrap` gives a serialized
shell session its current active states without starting new incarnations.

`Attached` carries the first complete value for an incarnation. `Changed`
carries a complete new value, not a diff. `Removed` ends the incarnation.

A batch can be empty. An empty batch is still one delivery and requires one
acknowledgment. One token acknowledges the complete atomic batch.

The public commit interface exposes the batch and snapshot. Typed lookup returns
the ordered updates for one kind and key. The existential fold supports generic
adapters.

This interface has the greatest depth and locality. Eta Crux owns update
classification, removal, incarnation, bootstrap, and atomic delivery.

### Commit notification followed by typed pull

This design exposes one payload-free commit notification. The unanswered
`Driver.Delivery.t` is a frozen typed pull boundary for that commit.

The delivery token exposes the complete atomic batch and typed state lookup by
kind and key. Pull reads retained committed values. Pull never recomputes a
projection and never observes a later commit.

The token exposes `Updates` for advancement and `Bootstrap` for session
replacement. Acknowledgment closes the frozen observation and admits
post-commit work.

Identity transport uses direct typed pulls. Serialized transport uses a
driver-written notification followed by driver-written pull frames.

This interface has low work for selective local callers. Serialized adapters
need more protocol exchanges and explicit bounded-pull rules.

### Independent projection streams

Independent streams are not eligible.

Separate stream acknowledgments split one atomic projection batch. A shared
acknowledgment recreates a batch interface, so the streams are no longer
independent.

An empty commit has no stream update. Preserving the delivery fence then needs a
common commit event, which also recreates batch delivery or notification
followed by pull.

Per-stream queues also require loss, unbounded capacity, or a hidden join. Each
outcome conflicts with Eta Crux atomic delivery and bounded ownership.

Independent declaration remains useful. Typed `Projection.publish` occurrences
can feed one commit-scoped batch without creating independent delivery streams.

### Application publication through `Poll` and `Host_operation`

Application publication is not eligible for typed projection delivery.

`Poll` starts after output acknowledgment. It cannot publish a projection batch
inside the delivery fence that admits post-commit work.

A `Host_operation` response is request resolution. It is not delivery
acknowledgment and cannot latch `Adapter_delivery`.

Serialized session replacement does not replay requests. Therefore, this path
cannot provide a bootstrap snapshot without application-owned replay.

This design remains a valid recipe for application-owned post-commit host work.
It is not an Eta Crux projection-delivery interface.

### Comparison

| Concern | Snapshot push | Batch push | Notification and pull |
|---|---|---|---|
| Interface depth | High | Highest | High |
| Caller work | Low | Medium | Low for typed pulls |
| Adapter work | High | Low | Medium |
| Removal | Derived from absence | Explicit | Explicit in the pulled batch |
| Dynamic structure | Native | Native | Native |
| Typed heterogeneity | Typed lookup and fold | Typed lookup and fold | Typed pull and fold |
| Codec registration | Kind and schema | Kind and schema | Kind and schema |
| Identity transport | Direct typed snapshot | Direct typed batch | Direct typed pull |
| Serialized transport | Snapshot push | Batch push | Notification and pull |
| Atomic acknowledgment | One snapshot | One batch | One frozen commit |
| Bootstrap | Current snapshot | Distinct snapshot | Distinct pulled snapshot |

Changed complete-value batch push is the recommendation. It gives the canonical
projection terms direct public meaning and places the required behavior behind
one driver seam.

Complete snapshot push and notification followed by typed pull remain eligible.
This ticket recommends an interface but does not select it.

[Commit observation and ownership
contract](09-commit-observation-and-ownership-contract.md) owns the exact commit
and acknowledgment semantics. [Identity, codec, and wire
contract](10-identity-codec-and-wire-contract.md) owns wire representation and
projection handles. [Session replacement and
bootstrap](11-session-replacement-and-bootstrap.md) owns bootstrap sequencing.

No new ticket is necessary.
