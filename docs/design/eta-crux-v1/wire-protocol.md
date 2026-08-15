# Eta Crux V1 wire protocol

## Boundary

This file defines the data contract for a serialized driver binding.
[Semantic laws](semantic-laws.md) defines sequencing, rejection, session, and
equivalence.

The protocol has one projection profile. It sends changed complete-value
batches for advancements and complete snapshots for session replacement.

The protocol has no profile negotiation, fallback profile, catalog exchange,
catalog fingerprint, codec metadata, pull cursor, or paging.

Each direction has an independent unsigned 32-bit sequence. Each command and
result consumes one sequence.

## Shared projection data

```ocaml
type delivery_reason =
  [ `Advancement | `Session_replacement ]

type delivery_result =
  [ `Accepted | `Failed of string ]

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
```

`Advancement` requires `Updates`. `Session_replacement` requires `Bootstrap`.
Another pair is an invalid application payload.

An entry uses a positive unsigned 64-bit incarnation. The OCaml semantic type
is `int64`. Encoding and comparison use unsigned semantics.

`Removed` contains no value. `Attached` and `Changed` contain the complete new
value.

Items use catalog declaration order and then the kind key order. A recipient
rejects another order.

## Frames

```ocaml
type frame =
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
  | Crash_notify of {
      seq : int32;
      failure : Failure.portable;
    }
  | Crash_result of {
      seq : int32;
      reply_to : int32;
      result : delivery_result;
    }
  | Endpoint_invoke of {
      seq : int32;
      handle : bytes;
      payload : bytes;
    }
  | Endpoint_result of {
      seq : int32;
      reply_to : int32;
      result : endpoint_result;
    }
  | Request_start of {
      seq : int32;
      handle : bytes;
      payload : bytes;
    }
  | Request_start_result of {
      seq : int32;
      reply_to : int32;
      result : request_start_result;
    }
  | Request_dispatch of {
      seq : int32;
      request : bytes;
      operation : string;
      payload : bytes;
    }
  | Request_dispatch_result of {
      seq : int32;
      reply_to : int32;
      accepted : bool;
    }
  | Request_resolve of {
      seq : int32;
      request : bytes;
      payload : bytes;
    }
  | Request_resolve_result of {
      seq : int32;
      reply_to : int32;
      result : request_resolve_result;
    }
  | Request_cancel of {
      seq : int32;
      request : bytes;
    }
  | Request_cancel_result of {
      seq : int32;
      reply_to : int32;
      result : request_identity_result;
    }
  | Request_resolved of {
      seq : int32;
      request : bytes;
      payload : bytes;
    }
  | Request_closed of {
      seq : int32;
      request : bytes;
      reason : closure_reason;
    }
```

`Request_resolved` and `Request_closed` are terminal notifications. They have
no result frame.

## Tags

| Constructor | Tag |
|---|---|
| `Projection_deliver` | `projection.deliver` |
| `Projection_result` | `projection.result` |
| `Crash_notify` | `crash.notify` |
| `Crash_result` | `crash.result` |
| `Endpoint_invoke` | `endpoint.invoke` |
| `Endpoint_result` | `endpoint.result` |
| `Request_start` | `request.start` |
| `Request_start_result` | `request.start_result` |
| `Request_dispatch` | `request.dispatch` |
| `Request_dispatch_result` | `request.dispatch_result` |
| `Request_resolve` | `request.resolve` |
| `Request_resolve_result` | `request.resolve_result` |
| `Request_cancel` | `request.cancel` |
| `Request_cancel_result` | `request.cancel_result` |
| `Request_resolved` | `request.resolved` |
| `Request_closed` | `request.closed` |

## JSON encoding

One closed JSON object represents one frame. `seq` and `tag` are the first
fields.

A projection delivery uses `reason`, `content`, and `entries`. `content` is
`updates` or `bootstrap`.

A projection entry uses this field order:

1. `kind`
2. `key`
3. `incarnation`
4. `value`

A projection update adds `update` before these fields. A `removed` update omits
`value`.

An accepted result uses `seq`, `tag`, `reply_to`, and `outcome`. A failed result
adds `message`.

Unsigned 32-bit values use JSON integers. Incarnations use canonical unsigned
decimal strings.

Bytes use unpadded base64url strings. A decoder rejects noncanonical bytes.

## S-expression encoding

One flat list represents one frame. The first two atoms are `seq` and `tag`.

A projection delivery has this form:

```text
(seq projection.deliver reason content count item-fields...)
```

The count uses canonical unsigned decimal. It equals the number of entries or
updates.

An update starts with its update tag. Its remaining fields use semantic order.
A removed update has no value atom.

Projection results have these forms:

```text
(seq projection.result reply-to accepted)
(seq projection.result reply-to failed message-bytes)
```

Bytes and diagnostic text use unpadded base64url atoms.

## Recipient checks

The recipient decodes the complete projection payload before host mutation. It
rejects these payload conditions:

- an unknown kind
- an invalid or noncanonical key
- a zero incarnation
- noncanonical item order
- a duplicate snapshot identity
- an invalid update transition
- a codec error
- a capacity excess

These conditions produce one failed `projection.result`. They keep the session
open and preserve the prior delivered state.

The recipient decodes and re-encodes each key. It requires byte equality. It
uses the kind comparator for identity and duplicate detection.

Installation replaces the complete host-visible state in one transaction. The
recipient advances delivered state before it sends `accepted`.

## Structural errors and bounds

These errors close the session:

- a malformed envelope
- an invalid frame sequence
- an invalid result correlation
- an invalid result diagnostic
- a frame that exceeds `max_frame_bytes`

`max_frame_bytes` must be positive. The session applies it before decode and
after encode.

The driver does not split or truncate an oversize projection. The delivery
fails with trigger `Projection_delivery`.

A failed projection result contains redacted valid UTF-8. The limit is 1,024
bytes. The protocol does not truncate a longer diagnostic.

## Session replacement

The first delivery on a replacement session is `Bootstrap`. It contains the
driver-retained committed snapshot and the active incarnation values.

The replacement sequence is:

1. Run replacement preflight.
2. Create the fresh export registry.
3. Encode the bootstrap with that registry.
4. Close the old session.
5. Send the bootstrap.
6. Settle old-session permits.
7. Wait for the result and lift the advancement fence.

Initial session attachment has no bootstrap. The first commit sends
`Attached` advancement updates.

## Portable failure encoding

`Failure.encode_portable` uses the `ECF1` magic. It encodes one primary record
and a length-prefixed secondary-record list.

Each record contains a portable cause, one origin byte, one trigger byte, and a
signed 64-bit big-endian observation position.

Portable trigger byte 11 is `Projection_delivery`. `Projection_preflight` is a
local transition trigger and does not add a transport profile.

## Operation names

An operation name starts with a lowercase ASCII letter. Later bytes can be
lowercase ASCII letters, digits, periods, underscores, or hyphens.

The maximum operation-name length is 128 bytes. Names are unique in one
binding.
