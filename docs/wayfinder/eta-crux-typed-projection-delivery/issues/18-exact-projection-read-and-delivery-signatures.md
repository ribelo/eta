# Exact projection read and delivery signatures

Type: grilling
Status: resolved
Blocked by: 16

## Question

What are the exact public OCaml signatures for the projection read and
delivery surface?

The selected interface names these types but does not pin their signatures:

- `Projection.Snapshot.t`, `Projection.Batch.t`, and `Projection.Commit.t`
  with their accessors. [Alternative public
  interfaces](08-alternative-public-interfaces.md) says the public commit
  interface exposes the batch and the snapshot. State the exact accessors.
- The public update type. Typed batch lookup by kind and key returns the
  ordered update list for one identity. State how an update carries the typed
  key, incarnation, and value for one `('key, 'value) Kind.t`.
- The rank-2 existential fold over snapshots and batches. State its exact
  form, for example an existential entry wrapper or a record of polymorphic
  functions. Compare the alternatives with Design It Twice.
- The `Root.advance` result type with `Projection.Commit.t`.
- The `Driver.Delivery.t` exposure of the typed `Projection.delivery`, the
  `Adapter.delivery` signature without `'output`, and the `Hosted.run`
  signature without `'output`.
- The public `Wire.Frame.t` projection variants in `eta_crux.mli`. The
  semantic frame data and grammars in [Identity, codec, and wire
  contract](10-identity-codec-and-wire-contract.md) already fix their
  content.

Every signature must preserve the opacity rules. Snapshots, batches, commits,
and incarnations stay opaque. No production query exposes delivered state.

## Answer

The user approved every recommended option. This answer pins the exact public
signatures. All types live in `eta_crux.mli`. [Implementation
plan](15-implementation-plan.md) change 2 item 2 implements the `Projection`
module; items 4 and 5 implement the driver and wire changes.

### Update type

One shared entry record serves snapshot attachments and the `Attached` and
`Changed` payloads:

```ocaml
type ('key, 'value) entry = {
  key : 'key;
  incarnation : Incarnation.t;
  value : 'value;
}

type ('key, 'value) update =
  | Attached of ('key, 'value) entry
  | Changed of ('key, 'value) entry
  | Removed of { key : 'key; incarnation : Incarnation.t }
```

An update carries the typed key even when typed lookup already fixed the key.
One update type then serves both typed lookup and the existential fold.

Entries and updates are concrete read views. Caller construction of an entry
grants no authority: the containers stay abstract, and callers cannot construct
incarnations. The typed shapes mirror the wire shapes one-to-one: `entry`
pairs with `projection_entry`, and `update` pairs with `projection_update`.

### Snapshot, Batch, and Commit

```ocaml
module Snapshot : sig
  type t

  val find_opt :
    ('key, 'value) Kind.t ->
    key:'key ->
    t ->
    ('key, 'value) entry option

  type packed_entry =
    | Pack : ('key, 'value) Kind.t * ('key, 'value) entry -> packed_entry

  val fold : t -> init:'acc -> f:('acc -> packed_entry -> 'acc) -> 'acc
end

module Batch : sig
  type t

  val find_opt :
    ('key, 'value) Kind.t ->
    key:'key ->
    t ->
    ('key, 'value) update list

  type packed_update =
    | Pack : ('key, 'value) Kind.t * ('key, 'value) update -> packed_update

  val fold : t -> init:'acc -> f:('acc -> packed_update -> 'acc) -> 'acc
end

module Commit : sig
  type t
  val snapshot : t -> Snapshot.t
  val batch : t -> Batch.t
end

type delivery =
  | Updates of Batch.t
  | Bootstrap of Snapshot.t
```

`find_opt` returns the complete attachment. [Identity, codec, and wire
contract](10-identity-codec-and-wire-contract.md) defines an attachment as
kind, key, incarnation, and value, so typed lookup exposes the incarnation.
The name follows the repository `find_opt` convention. Neither module adds
`length` or `is_empty`; the fold covers counting.

The fold uses the GADT pack form, the same pattern as `Kind.packed` and
`Host_operation.packed`. The caller matches `Pack (kind, entry)` and recovers
the typed key and value locally. The rejected alternative was a rank-2 record
of polymorphic functions. It saves one pack allocation per entry but is the
only rank-2 record in the codebase and is harder to construct inline. The
per-entry codec work dominates the pack allocation.

The snapshot fold carries untagged entries: a bootstrap snapshot has no update
tags. The batch fold carries tagged updates. Both folds enumerate in canonical
order: catalog declaration order, then `key_compare` order (PRJ-26).

`Commit.t` exposes the batch and the snapshot, and nothing else. [Commit
observation and ownership contract](09-commit-observation-and-ownership-contract.md)
forbids a commit identity, revision, delivery state, or terminal-state query.

### Root

```ocaml
module Root : sig
  type t

  type delivery_error =
    | Stale_endpoint
    | Stale_reset

  type advance_error =
    | Already_advancing
    | Awaiting_post_commit
    | Closed
    | Driver_attached

  type outcome =
    | Idle
    | Rejected of delivery_error
    | Committed of {
        commit : Projection.Commit.t;
        post_commit : Post_commit.t;
      }
    | Stopped of {
        post_commit : Post_commit.t;
      }
    | Failed of {
        failure : Failure.t;
        post_commit : Post_commit.t;
      }

  val create :
    ?post_commit_effect_observer:Testing.post_commit_effect_observer ->
    catalog:Projection.Catalog.t ->
    projection_capacity:int ->
    ingress_capacity:int ->
    request_capacity:int ->
    _ Eta_crux.t ->
    t

  val advance :
    t ->
    ((outcome, advance_error) result, never) Eta.Effect.t

  val request_stop : t -> unit
end
```

The `'output` parameter is removed. `Committed` carries the commit instead of
the output. The remaining cases and `create` labels are unchanged apart from
the added `catalog:` and `projection_capacity:`.

### Driver, Adapter, and Hosted

```ocaml
module Driver : sig
  type t

  module Binding : sig
    type t

    val identity :
      Host_operation.packed list ->
      t

    val serialized :
      operations:Host_operation.packed list ->
      session:Serialized_session.candidate ->
      t * Serialized_session.admin

    val requester :
      t ->
      ('request, 'response) Host_operation.t ->
      ('request, 'response) Requester.t
  end

  type terminal =
    | Stopped
    | Crashed of Failure.settlement

  module Delivery : sig
    type reason =
      | Advancement
      | Session_replacement

    type t
    type completion_error = Already_completed

    val projection : t -> Projection.delivery
    val reason : t -> reason

    val delivered :
      t ->
      ((unit, completion_error) result, never) Eta.Effect.t

    val failed :
      t ->
      Failure.Packed_cause.t ->
      ((unit, completion_error) result, never) Eta.Effect.t
  end

  type event =
    | Deliver of Delivery.t
    | Request of Request.Driver_event.t
    | Rejected of Root.delivery_error
    | Crash_detected of Failure.t
    | Closed of terminal

  val create : Binding.t -> Root.t -> t
  val poll : t -> (event option, never) Eta.Effect.t
  val await : t -> (event, never) Eta.Effect.t
  val latest_committed_snapshot : t -> Projection.Snapshot.t option
  val request_stop : t -> unit
end

module Adapter : sig
  type 'error resource

  type delivery = {
    projection : Projection.delivery;
    reason : Driver.Delivery.reason;
  }

  val resource :
    pp_error:(Format.formatter -> 'error -> unit) ->
    acquire:('binding, 'error) Eta.Effect.t ->
    release:('binding -> (unit, 'error) Eta.Effect.t) ->
    deliver:
      ('binding ->
       delivery ->
       (unit, 'error) Eta.Effect.t) ->
    request_event:
      ('binding ->
       Request.Driver_event.t ->
       (unit, 'error) Eta.Effect.t) ->
    crash_detected:
      ('binding ->
       Failure.t ->
       (unit, 'error) Eta.Effect.t) ->
    'error resource
end

module Hosted : sig
  module Control : sig
    type t
    val request_stop : t -> unit
  end

  val run :
    Driver.t ->
    adapter:(Control.t -> 'error Adapter.resource) ->
    (Driver.terminal, 'error) Eta.Effect.t
end
```

`Delivery.projection` replaces `Delivery.output`. The name avoids the
`delivery.delivery` stutter and the wire-term collision with
`projection_content`. The adapter record keeps its current shape with
`projection` in place of `output`. Every `'output` parameter is removed:
`Root.t`, `Driver.t`, `Binding.t`, `Delivery.t`, `event`, `Adapter.resource`,
and `Hosted.run` lose it. `Binding.serialized` loses `output:`; codecs live in
kinds.

### Wire frames

```ocaml
module Wire : sig
  module Frame : sig
    type projection_entry = {
      kind : string;
      key : bytes;
      incarnation : int64;
      value : bytes;
    }

    type projection_update =
      | Attached of projection_entry
      | Changed of projection_entry
      | Removed of {
          kind : string;
          key : bytes;
          incarnation : int64;
        }

    type projection_content =
      | Updates of projection_update list
      | Bootstrap of projection_entry list

    type t =
      | Projection_deliver of {
          seq : int32;
          reason : delivery_reason;
          content : projection_content;
        }
      | Projection_result of {
          seq : int32;
          reply_to : int32;
          result : delivery_result;
        }
      | (* Crash_*, Endpoint_*, and Request_* variants unchanged *)
  end
end
```

`Output_deliver` and `Output_result` are deleted in the same change.

The incarnation field is `int64` with a documented unsigned 64-bit contract;
zero is invalid. Every 64-bit counter in `lib/crux` already uses `int64`, and
`Incarnation_exhausted` fires as a preflight error before the practical range
matters. The codecs print and parse the field as a canonical unsigned decimal
per the grammar in [Identity, codec, and wire
contract](10-identity-codec-and-wire-contract.md). No abstract `uint64` type
is added.

The variants reuse the existing `delivery_reason` and `delivery_result` types.
The shapes and the delivery fence are identical to the deleted output frames,
and each layer keeps its own naming level: `projection_reason` and
`projection_result` remain the semantic-level names in the wire contract. The
bounded, redacted diagnostic stays a codec and protocol contract; it needs no
distinct type.

### Opacity and gates

`Snapshot.t`, `Batch.t`, `Commit.t`, and `Incarnation.t` are abstract. No
signature above exposes delivered state, so PRJ-30 holds. PRJ-27 gates typed
lookup and both folds through `test_projection_typed_lookup_fold`. PRJ-15
gates incarnation opacity. PRJ-26 gates the fold order.

[Design package approval](17-design-package-approval.md) is unblocked. No new
ticket is necessary.
