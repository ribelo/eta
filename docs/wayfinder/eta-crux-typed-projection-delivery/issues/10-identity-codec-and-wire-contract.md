# Identity, codec, and wire contract

Type: grilling
Status: resolved
Blocked by: 08, 09

## Question

How must static and dynamic identities, heterogeneous values, codecs, handles,
and serialized frames work?

Define identity continuity, collision rejection, removal and re-entry, codec
fixity, remote-handle scope, and cutoff behavior.

Define identity-binding observations and serialized frames. Specify frame-size
limits, batch capacity, encode failure, decode failure, write failure, adapter
rejection, and acknowledgment outcomes.

Make sure that the driver is the only transport writer and that the adapter
applies one batch atomically.

## Answer

### First principle

One framework-owned projection image is the only committed outward value. The
image comes from structural `Projection.publish` occurrences. The ordinary root
computation result remains local.

`Projection` and `Endpoint` are separate public concepts. A projection carries
committed state from the core to the shell. An endpoint grants authority to send
actions from the shell to the core.

The two concepts can share private structural registration machinery. They do
not share identity, admission, capacity, acknowledgment, or remote handles.

Projection values can contain `Exported_endpoint.t` and `Request_export.t`.
Thus, one projection image can carry committed state and shell capabilities
atomically.

### Common public contract

The shared codec becomes fallible in both directions:

```ocaml
module Codec : sig
  type encode_error = { message : string }
  type decode_error = { message : string }
  type 'a t

  val make :
    encode:('a -> (bytes, encode_error) result) ->
    decode:(bytes -> ('a, decode_error) result) ->
    'a t

  val encode : 'a t -> 'a -> (bytes, encode_error) result
  val decode : 'a t -> bytes -> ('a, decode_error) result
end
```

The common projection surface is:

```ocaml
module Projection : sig
  module Incarnation : sig
    type t
    val equal : t -> t -> bool
    val compare : t -> t -> int
  end

  module Kind : sig
    type ('key, 'value) t
    type packed = Pack : ('key, 'value) t -> packed

    val define :
      name:string ->
      key_compare:('key -> 'key -> int) ->
      key_codec:'key Codec.t ->
      value_codec:'value Codec.t ->
      value_equal:('value -> 'value -> bool) ->
      cutoff:'value Cutoff.t ->
      ('key, 'value) t
  end

  module Catalog : sig
    type t
    val create : Kind.packed list -> t
  end

  type preflight_error =
    | Unknown_kind
    | Identity_collision
    | Projection_capacity_exceeded
    | Incarnation_exhausted

  val publish :
    ('key, 'value) Kind.t ->
    key:'key ->
    'value Eta_crux.t ->
    'value Eta_crux.t
end

module Failure : sig
  module Packed_cause : sig
    type t

    val projection_preflight :
      t ->
      Projection.preflight_error option
  end
end

module Requester : sig
  type ('request, 'response) t

  type error =
    | Ingress_closed
    | Encode_failed of Codec.encode_error
    | Decode_failed of Codec.decode_error
    | Dispatch_failed
    | Closed of Request.closure_reason

  val request :
    ('request, 'response) t ->
    'request ->
    ('response, error) Eta.Effect.t
end

module Responder : sig
  type 'response t

  type error =
    | Not_pending
    | Encode_failed of Codec.encode_error

  val resolve :
    'response t ->
    'response ->
    (unit, error) Eta.Effect.t
end

module Root : sig
  type t

  val create :
    catalog:Projection.Catalog.t ->
    projection_capacity:int ->
    ingress_capacity:int ->
    request_capacity:int ->
    _ Eta_crux.t ->
    t
end

```

`Projection.Catalog` replaces the earlier name `Projection.Schema`. A catalog is
a closed, ordered set of kinds. It is not a data schema.

`eta_crux` remains independent of `eta_schema`. Applications can adapt
`Eta_schema.t` to `Codec.t` when they select JSON. No integration package is
part of this design.

### Kind and catalog rules

Each `Projection.Kind.define` call creates a distinct kind. Equal arguments do
not merge descriptor instances.

A kind fixes these properties for its complete lifetime:

- its wire name
- its key order
- its key codec
- its value codec
- its value equality
- its publication cutoff

The wire name identifies the kind across serialized transport. It does not
define local descriptor identity.

`Projection.Catalog.create` accepts an empty list. It rejects these conditions
with `Invalid_argument` before a root exists:

- the same descriptor occurs more than once
- two descriptors use the same wire name
- a wire name does not match `[a-z][a-z0-9._-]*`
- a wire name contains more than 128 bytes

Catalog construction cannot prove comparator or codec laws. Named generated
gates must prove those laws.

An immutable catalog can serve several roots. Each root owns separate committed
state, capacity, and incarnation allocation.

`Root.create` requires a positive `projection_capacity`. The catalog and this
capacity are fixed for the root lifetime.

### Projection identity

A projection identity is the pair of one exact `Kind.t` instance and one key.
`key_compare left right = 0` defines key equivalence.

`key_compare` must define a stable total order. The same relation controls
identity, lookup, collision detection, and deterministic order.

The key codec must satisfy these laws:

- Equivalent keys either both encode successfully or both return
  `encode_error`.
- Successful encodings of equivalent keys produce identical bytes.
- Successful encodings of non-equivalent keys produce different bytes.
- Decoding encoded bytes returns an equivalent key.

If key encoding returns `encode_error`, serialized delivery fails before it
creates a wire identity. The committed typed identity remains unchanged.

Serialized key bytes are canonical. A receiver decodes each key, encodes it
again, and requires byte equality. It then uses `key_compare` to detect
equivalent duplicate identities.

Keys must be session-independent. They cannot contain `Exported_endpoint.t` or
`Request_export.t`. Projection values can contain those capabilities.

The value codec has one round-trip law. Decoding an encoded value must return a
value equivalent under `value_equal`.

Value bytes need not have one canonical representation. Publication cutoff is
not codec equality and need not be an equivalence relation.

Identity delivery performs no codec work. Each typed entry carries the exact
kind, typed key, opaque incarnation, and complete typed value.

### Attachment, collision, and incarnation

One final committed image can contain at most one active attachment for each
projection identity. Two final active attachments collide even when their
values compare equal.

Each `Projection.publish` occurrence has one private structural identity. The
identity remains stable during one continuous active structural interval.

The retained incarnation continues only when the same structural occurrence
publishes the same projection identity in consecutive committed images.

These changes end the prior incarnation:

- the structural occurrence becomes absent
- the occurrence re-enters after absence
- the occurrence changes its kind
- its key changes to a non-equivalent key
- another occurrence becomes the owner of the same projection identity

Removal ends the active incarnation but does not destroy the logical identity.
A later attachment of the same kind and equivalent key starts a new
incarnation.

A commit can remove one occurrence and attach one replacement for the same
identity. This is a valid replacement, not a collision. Its updates are
`Removed` followed by `Attached`.

Eta Crux allocates each incarnation. It uses a positive unsigned 64-bit root
counter. Zero is invalid.

Incarnations are unique and never reused during one root lifetime. Session
replacement preserves active incarnation values.

Preflight first validates the complete candidate image. Eta Crux then allocates
new incarnation values in deterministic batch order. A failed advancement
consumes no incarnation values.

Counter exhaustion is `Incarnation_exhausted`. It is a pre-commit structural
failure.

`Projection.Incarnation.t` remains opaque. Callers can compare values but cannot
construct them or access their wire representation.

### Cutoff and retained values

`Projection.publish` returns its candidate value to local computation. The
publication cutoff changes only the outward image.

For an existing incarnation, Eta Crux compares the prior retained value with the
candidate. If the cutoff suppresses the candidate, the committed image keeps the
prior complete value and emits no `Changed`.

Cutoff cannot suppress `Attached` or `Removed`.

If `key_compare` or cutoff raises, the exception is a pre-commit defect. Eta
Crux preserves the prior commit and emits no delivery.

### Preflight and capacity

The positive `projection_capacity` independently bounds:

- active projection identities in the committed image
- update records in one ordinary batch
- entries in one bootstrap snapshot

A replacement consumes two update records. Eta Crux never chunks, drops, or
coalesces records to satisfy this capacity.

These closed preflight errors are fatal:

- `Unknown_kind`
- `Identity_collision`
- `Projection_capacity_exceeded`
- `Incarnation_exhausted`

`Root.advance` returns `Failed` with `Failure.t`. The cause contains the exact
`Projection.preflight_error`. These errors are not nonfatal `Root.Rejected`
outcomes.

`Failure.Packed_cause.projection_preflight` returns this typed error. It returns
`None` for every other packed cause.

Preflight failures use origin `Transition` and trigger
`Projection_preflight`. Comparator and cutoff exceptions use the same trigger
but retain their local exception cause.

Every preflight failure preserves the prior committed image, emits no delivery,
and starts no ordinary post-commit work.

### Typed snapshots and batches

A snapshot contains every active projection attachment. Each attachment
contains its kind, key, incarnation, and complete retained value.

An update has one of these forms:

- `Attached` contains the identity, new incarnation, and complete value.
- `Changed` contains the identity, existing incarnation, and complete value.
- `Removed` contains the identity and ended incarnation.

An advancement batch applies to the recipient's prior delivered snapshot. Each
identity has one of these valid transition sequences:

- `Absent` followed by `Attached new`
- `Active old` followed by `Changed old`
- `Active old` followed by `Removed old`
- `Active old` followed by `Removed old`, then `Attached new`
- no update

For `Changed`, the update incarnation must equal the active incarnation. For
`Removed`, it must equal the active incarnation.

For `Attached`, the target state must be absent. Its incarnation must be
nonzero and different from the removed incarnation in a replacement.

An identity has at most two updates in one batch. The only two-update sequence
is adjacent `Removed`, then `Attached`.

The initial advancement starts from an empty delivered snapshot. Therefore, it
contains only `Attached` updates.

A bootstrap snapshot stands alone. It contains one active entry for each
identity and no update tags.

Snapshot and batch types are opaque. They provide typed lookup by kind and key.
They also provide a rank-2 existential fold for generic adapters.

Batch lookup returns an ordered update list. It usually contains zero or one
update. A replacement returns adjacent `Removed` and `Attached` updates.

Snapshot and batch folds use catalog declaration order, then `key_compare`
order. Serialized entries use this same canonical order.

The shell rejects an entry sequence that is not in canonical order. It does not
sort or repair the sequence.

An empty catalog and an empty projection image are valid. Every successful
commit still creates one delivery and requires one acknowledgment.

### Projection handles and export handles

There is no projection remote handle. Serialized entries use the kind wire name,
encoded key, and root-lifetime incarnation.

A projection grants no later invocation authority. A session slot, generation,
and authenticator duplicate identity without adding a legal operation.

Export handles remain session-scoped capabilities. After commit, the driver
builds or updates the committed export registry. It then runs projection value
codecs inside the existing remote-handle encoding fence.

If a value codec requests a handle for an export absent from the committed
registry, `remote_handle` raises. The commit remains published, but delivery
fails as an `Adapter_delivery` defect.

Identity delivery carries typed exported endpoints and request exports directly.
It allocates no remote handles and calls no codecs.

### Protocol profiles

The three eligible interfaces have separate protocol profiles:

1. complete snapshot push
2. changed complete-value batch push
3. notification followed by bounded pull

The final interface selection keeps exactly one profile. The protocol has no
profile negotiation, compatibility fallback, or dormant tags for the rejected
profiles.

Both peers implement the same fixed projection catalog. The protocol has no
catalog exchange, catalog fingerprint, or codec metadata.

The root is the sole local owner of its catalog and capacity. The attached
driver reads both values from the root.

The foreign shell receives matching catalog and capacity configuration
separately. The protocol does not transmit or negotiate either value.

Each serialized entry contains:

- the kind wire name
- the encoded key
- the positive root-lifetime incarnation
- the encoded complete value, unless the update is `Removed`
- the update tag, when the payload is an update batch

The push profiles use `projection.deliver` and `projection.result`. The pull
profile uses `projection.notify`, `projection.pull`,
`projection.pull_result`, and `projection.result`.

`projection.result` reports `accepted` or `failed` for the complete atomic
delivery. One result acknowledges one delivery.

`failed` carries one redacted UTF-8 diagnostic of at most 1,024 bytes. A longer
or invalid diagnostic is an invalid result field. It closes the session. Eta
Crux never truncates the diagnostic.

JSON encodes an accepted result with fields `seq`, `tag`, `reply_to`, and
`outcome`. The outcome is `accepted`.

JSON encodes a failed result with those fields and `message`. The outcome is
`failed`. `message` contains the diagnostic as UTF-8 text.

The flat S-expression result forms are:

```text
(seq projection.result reply-to accepted)
(seq projection.result reply-to failed message-bytes)
```

`message-bytes` is the UTF-8 diagnostic in unpadded base64url.

### Common semantic frame data

All profiles retain the existing independent unsigned 32-bit sequences. Each
command and result consumes one sequence.

A `projection.result` references the sequence of its delivery command. A
`projection.pull_result` references the sequence of its pull command.

The common semantic data is:

```ocaml
type projection_reason =
  [ `Advancement | `Session_replacement ]

type projection_result =
  [ `Accepted | `Failed of string ]

type projection_entry = {
  kind : string;
  key : bytes;
  incarnation : uint64;
  value : bytes;
}

type projection_update =
  | Attached of projection_entry
  | Changed of projection_entry
  | Removed of {
      kind : string;
      key : bytes;
      incarnation : uint64;
    }
```

`uint64` is an unsigned 64-bit semantic value. Zero is invalid for an
incarnation.

JSON encodes `uint64` as a canonical decimal string. S-expressions encode it as
a canonical decimal atom. Leading zeroes are invalid, except for zero itself.

JSON encodes bytes as unpadded base64url. S-expressions use the same encoding.
Existing noncanonical-byte rejection remains unchanged.

JSON projection entries are objects in an `entries` array. The object fields
use the order `kind`, `key`, `incarnation`, and `value`.

JSON updates add `update` before those fields. `Removed` omits `value`.
Decoders reject unknown, duplicate, missing, and incorrectly typed fields.

The S-expression envelope remains one flat list. It contains an item count,
then repeated entry fields in semantic order.

Each S-expression update starts with its update tag. `Removed` has no value
atom. Decoders reject nesting, extra atoms, and wrong arity.

An opaque pull cursor contains at most 64 bytes. JSON and S-expressions encode
it as unpadded base64url.

### Complete snapshot push profile

This profile adds these frames:

```ocaml
| Projection_deliver of {
    seq : int32;
    reason : projection_reason;
    entries : projection_entry list;
  }
| Projection_result of {
    seq : int32;
    reply_to : int32;
    result : projection_result;
  }
```

The wire tags are `projection.deliver` and `projection.result`.

`projection.deliver` carries the delivery reason and one complete ordered active
snapshot. This rule applies to advancement and session replacement.

JSON uses fields `seq`, `tag`, `reason`, and `entries`.

The flat S-expression is:

```text
(seq projection.deliver reason count entry-fields...)
```

`count` is the canonical unsigned 64-bit decimal item count. It must equal the
number of encoded entries.

The frame can contain zero entries. The shell still returns one
`projection.result`.

### Changed complete-value batch push profile

This profile adds these frames:

```ocaml
type projection_content =
  | Updates of projection_update list
  | Bootstrap of projection_entry list

| Projection_deliver of {
    seq : int32;
    reason : projection_reason;
    content : projection_content;
  }
| Projection_result of {
    seq : int32;
    reply_to : int32;
    result : projection_result;
  }
```

The wire tags are `projection.deliver` and `projection.result`.

`Advancement` requires `Updates`. `Session_replacement` requires `Bootstrap`.
Any other pairing is an invalid application payload.

JSON uses fields `seq`, `tag`, `reason`, `content`, and `entries`. `content` is
`updates` or `bootstrap`.

The flat S-expression is:

```text
(seq projection.deliver reason content count item-fields...)
```

`count` is the canonical unsigned 64-bit decimal item count. It must equal the
number of encoded entries or updates.

For advancement, `projection.deliver` carries the ordered update batch. The
initial successful advancement carries `Attached` for each active projection.

For session replacement, `projection.deliver` carries the complete ordered
active snapshot. This snapshot is the bootstrap observation.

The shell returns one `projection.result` for the complete batch or snapshot.

### Notification followed by bounded pull profile

This profile adds these frames:

```ocaml
type projection_pull_content = [ `Updates | `Bootstrap ]

type projection_continuation =
  [ `Next of bytes | `Complete ]

type projection_page =
  | Update_page of projection_update list
  | Bootstrap_page of projection_entry list

type projection_pull_outcome =
  [ `Page of {
      page : projection_page;
      continuation : projection_continuation;
    }
  | `Unknown_notification
  | `Invalid_cursor
  | `Invalid_limit
  | `Entry_too_large ]

| Projection_notify of {
    seq : int32;
    reason : projection_reason;
    content : projection_pull_content;
    item_count : uint64;
  }
| Projection_pull of {
    seq : int32;
    notification : int32;
    cursor : bytes option;
    limit : uint64;
  }
| Projection_pull_result of {
    seq : int32;
    reply_to : int32;
    result : projection_pull_outcome;
  }
| Projection_result of {
    seq : int32;
    reply_to : int32;
    result : projection_result;
  }
```

The page constructor must match `content`. A page never mixes entries and
updates.

The wire tags are `projection.notify`, `projection.pull`,
`projection.pull_result`, and `projection.result`.

`projection.notify` carries the delivery reason, content, and exact item count.
The notification sequence is the frozen commit reference.

`Advancement` requires `Updates`. `Session_replacement` requires `Bootstrap`.

JSON uses these exact forms:

- `projection.notify` uses `seq`, `tag`, `reason`, `content`, and `item_count`.
- The initial `projection.pull` uses `seq`, `tag`, `notification`, `cursor`,
  and `limit`. `cursor` is `null`.
- A later `projection.pull` uses the same fields. `cursor` is unpadded
  base64url text.
- A page result uses `seq`, `tag`, `reply_to`, `outcome`, `content`, `entries`,
  and `continuation`.
- A page with more data also uses `cursor`.
- A closed pull error uses only `seq`, `tag`, `reply_to`, and `outcome`.

`outcome` is `page`, `unknown_notification`, `invalid_cursor`,
`invalid_limit`, or `entry_too_large`.

For a page, `content` is `updates` or `bootstrap`. `continuation` is `next` or
`complete`. The `cursor` field is present exactly when continuation is `next`.

`item_count` and `limit` are canonical unsigned 64-bit decimal strings.

The flat S-expression forms are:

```text
(seq projection.notify reason content item-count)
(seq projection.pull notification none limit)
(seq projection.pull notification next cursor-bytes limit)
(seq projection.pull_result reply-to page content count item-fields... next cursor-bytes)
(seq projection.pull_result reply-to page content count item-fields... complete)
(seq projection.pull_result reply-to unknown_notification)
(seq projection.pull_result reply-to invalid_cursor)
(seq projection.pull_result reply-to invalid_limit)
(seq projection.pull_result reply-to entry_too_large)
```

`item-count`, `limit`, and `count` are canonical unsigned 64-bit decimal atoms.
`cursor-bytes` is unpadded base64url.

For advancement, the frozen observation contains the ordered update batch. For
session replacement, it contains the complete ordered active snapshot.

Only one notification can be pending. The frozen observation remains valid
until its final result or session closure.

[Session replacement and bootstrap](11-session-replacement-and-bootstrap.md)
owns the exact later-commit and replacement races around this fence.

`projection.pull` contains:

- the notification sequence
- no cursor for the first request, or the exact next opaque cursor
- a positive item limit

`item_count` and `limit` must fit the configured projection capacity. Zero is
valid for `item_count` and invalid for `limit`.

The cursor belongs to one notification. It is single-use. An earlier, repeated,
or foreign cursor is invalid.

`projection.pull_result` has these closed outcomes:

- `Page` with a nonempty ordered prefix and continuation state
- `Unknown_notification`
- `Invalid_cursor`
- `Invalid_limit`
- `Entry_too_large`

Continuation state contains the next opaque cursor or `complete`.

A page is the greatest nonempty ordered prefix that satisfies the item limit.
The complete encoded `projection.pull_result` frame must also satisfy
`max_frame_bytes`.

The frame-size calculation includes the sequence, tag, reply target, outcome,
content, entries, continuation, and optional cursor.

If one entry cannot fit in a complete result frame, the result is
`Entry_too_large`. Entries never split across pages.

Unknown notifications, invalid cursors, invalid limits, and oversized entries
keep the session open. They do not look like valid empty pages.

A notification with zero items is already complete. The shell can acknowledge
it without a pull request.

The shell can return `projection.result failed` at any point after notification.
Failure releases the frozen observation and rejects the complete delivery.

The shell can return `accepted` only after complete retrieval, validation, and
atomic installation. Early acceptance is invalid correlation state and closes
the session.

### Frame validation and bounds

`max_frame_bytes` remains positive and explicit. It applies before frame decode
and after frame encode.

Push profiles use one delivery frame. If the complete payload exceeds
`max_frame_bytes`, Eta Crux closes the session with `Frame_too_large` and fails
the delivery. It does not split or truncate the payload.

In the pull profile, an entry that cannot fit produces `Entry_too_large`. The
shell then returns a failed final result.

A valid projection payload is rejected as a complete delivery when it contains
any of these conditions:

- an unknown kind
- an invalid or noncanonical key
- a zero incarnation
- entries outside canonical order
- duplicate snapshot identities
- invalid update transitions
- a codec error
- more entries than the shell projection capacity

These conditions return `projection.result failed` and keep the session open.
They are application-payload rejections, not structural envelope errors.

For an update batch, the shell validates every transition against its prior
delivered snapshot. It also validates the final item count and continuation.

A capacity mismatch has no fallback. A delivery above the shell limit fails
atomically.

Malformed envelopes, bad frame sequences, bad result correlation, and invalid
result diagnostics remain structural protocol errors. They close the session.

### Codec and delivery failures

Encoding runs after commit. If a key or value codec returns `encode_error`, the
commit remains published and the complete delivery fails.

If a codec raises, the failure retains the local exception cause. Eta Crux does
not convert the defect into a typed codec error.

Local encoding diagnostics never enter frames. A shell decode failure returns
one bounded, redacted failed-delivery diagnostic. The diagnostic can identify
the kind and field but cannot contain payload data.

Frame-size failure, transport-write failure, session loss, and remote adapter
rejection all fail the complete pending delivery. Eta Crux does not retry.

Each case is a delivery failure under [Commit observation and ownership
contract](09-commit-observation-and-ownership-contract.md). Its failure trigger
is `Projection_delivery`.

`Projection_delivery` replaces the former `Output_delivery` trigger.

The driver remains the only transport writer.

### Shared codec effects

A returned decode error remains `Malformed_payload` for `Exported_endpoint` and
inbound `Request_export` requests. Eta Crux enqueues nothing, keeps the session
open, and does not crash the root.

An outbound `Host_operation` request encode error returns
`Requester.Encode_failed`. It allocates no request identity, consumes no request
capacity, and emits no driver event.

An inbound `Request_export` response encode error makes `Responder.resolve`
return `Responder.Encode_failed`. The request remains pending, so its owner can
resolve it again.

A host-operation response decode error returns `Requester.Decode_failed`. Eta
Crux closes only that request and keeps the session open.

Codec exceptions remain defects. Existing failure origins and triggers identify
the active export or request boundary.

### Adapter atomicity

The adapter decodes and validates the complete delivery before host mutation.
It then installs the complete new projection state as one host-visible
transaction.

If installation fails, the prior delivered state remains observable. Partial
state must not become visible.

The adapter advances delivered state before it returns `accepted`. State
installation, delivered-state advancement, and successful acknowledgment form
one logical completion point.

The shell can reject unknown kinds, noncanonical keys, invalid transitions,
duplicate identities, codec errors, and capacity errors. It applies nothing and
returns one failed result.

### Relationship to later tickets

[Session replacement and bootstrap](11-session-replacement-and-bootstrap.md)
owns replacement ordering and races. [Laws and deterministic test
controls](12-laws-and-deterministic-test-controls.md) owns the named gates for
the laws in this answer.

No new ticket is necessary.
