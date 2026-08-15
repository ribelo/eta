---
kind: issue
status: ready-for-agent
requirements:
  - crxprj-iczc
  - crxprj-oohc
  - crxprj-oghw
  - crxprj-fnj3
  - crxprj-0ai1
  - crxprj-hohr
  - crxprj-bmrc
  - crxprj-zcav
  - crxprj-urbd
  - crxprj-bqd3
  - crxprj-3mtt
  - crxprj-vtpn
  - crxprj-1jit
  - crxprj-c7oo
  - crxprj-k7i6
  - crxprj-4sl4
  - crxprj-29xj
  - crxprj-x10z
  - crxprj-thta
  - crxprj-0yei
  - crxprj-h9g9
  - crxprj-wt0g
  - crxprj-qtij
  - crxprj-n6m4
  - crxprj-csat
  - crxprj-5uvd
  - crxprj-2qe1
  - crxprj-grfp
  - crxprj-022s
  - crxprj-x6h6
  - crxprj-hu3l
  - crxprj-eqkj
  - crxprj-a2lh
  - crxprj-io2y
  - crxprj-o1uj
  - crxprj-02pk
  - crxprj-jcmu
  - crxprj-ma3z
  - crxprj-ipui
  - crxprj-0jbu
  - crxprj-z5gu
  - crxprj-tcb7
  - crxprj-hwlg
  - crxprj-t5kp
  - crxprj-7dej
  - crxprj-mhys
  - crxprj-md57
  - crxprj-htsl
  - crxprj-56ig
  - crxprj-o4aq
  - crxprj-96kb
  - crxprj-mtx2
  - crxprj-9fjf
  - crxprj-1fte
  - crxprj-bto6
  - crxprj-9h4r
  - crxprj-v93q
  - crxprj-aeuq
  - crxprj-u36h
  - crxprj-1gdf
  - crxprj-edzh
  - crxprj-8mxg
  - crxprj-erna
  - crxprj-zwar
  - crxprj-ux42
  - crxprj-ukqw
  - crxprj-n23f
  - crxprj-20xp
  - crxprj-xzh4
  - crxprj-pe2t
  - crxprj-saet
  - crxprj-hdte
  - crxprj-4jn2
  - crxprj-4duc
  - crxprj-8bfj
  - crxprj-bryz
  - crxprj-a5pq
  - crxprj-80tl
  - crxprj-uk4q
  - crxprj-291b
  - crxprj-z3ry
  - crxprj-m27l
  - crxprj-5sh6
  - crxprj-xd9s
  - crxprj-uxyx
  - crxprj-3jk4
  - crxprj-1uw3
  - crxprj-1d5m
  - crxprj-wam3
  - crxprj-gc9i
  - crxprj-1fo8
  - crxprj-rovw
  - crxprj-cnaj
  - crxprj-sl78
  - crxprj-boby
  - crxprj-qigm
  - crxprj-xh4l
  - crxprj-9ome
  - crxprj-mxly
  - crxprj-oot4
  - crxprj-43y5
  - crxprj-ufyv
  - crxprj-i9wx
  - crxprj-ujwi
  - crxprj-4i0y
  - crxprj-ocex
  - crxprj-bl0a
  - crxprj-xgql
  - crxprj-cyq1
  - crxprj-vkn6
  - crxprj-ytcu
  - crxprj-u0u6
  - crxprj-gbs2
  - crxprj-ueje
  - crxprj-ql9u
  - crxprj-da2s
  - crxprj-b3gd
  - crxprj-8047
  - crxprj-oazz
  - crxprj-v0ie
  - crxprj-b30d
  - crxprj-xm6p
  - crxprj-bejf
  - crxprj-k9x3
  - crxprj-vii3
  - crxprj-yvmd
  - crxprj-sbyz
  - crxprj-h935
  - crxprj-44kq
  - crxprj-kr1l
  - crxprj-19o8
  - crxprj-aiag
  - crxprj-ogzt
  - crxprj-yq72
  - crxprj-f4pe
  - crxprj-pc3u
  - crxprj-2u5g
  - crxprj-noqf
  - crxprj-crsj
  - crxprj-kipf
  - crxprj-wkgm
  - crxprj-eyav
  - crxprj-2oyz
  - crxprj-v087
  - crxprj-jmdc
  - crxprj-slkt
  - crxprj-jubd
  - crxprj-rndm
  - crxprj-yw13
  - crxprj-3hd9
  - crxprj-7i6u
  - crxprj-zieq
  - crxprj-cj3l
  - crxprj-2xu1
  - crxprj-r3mt
  - crxprj-f5zb
  - crxprj-fox3
  - crxprj-dgb7
  - crxprj-v5b5
---

# Typed projection delivery

## Problem Statement

Eta Crux delivers one complete root output per commit. The output is one opaque
application value with one application codec. Every keyed or structured shell
state must travel inside that value.

This puts the whole reconciliation problem on the application:

- The shell receives one whole value per commit. It must diff that value itself
  to learn which row changed. Eta Crux owns commit atomicity and delivery
  acknowledgment, but not change classification, so each adapter reinvents it.
- Serialized bytes are proportional to the complete output, not to the changed
  part. One changed row among 100,000 encodes 100,000 rows.
- Identity has no framework meaning. The application cannot tell a continuing
  row from a removed and re-added row, because the output carries no incarnation.
- A shell session that is replaced has no way to get current state. The
  application must replay or resynchronize, which Eta Crux does not own.
- `Codec.encode` cannot fail, so an unencodable value has no typed outcome.

## Solution

Replace complete root-output delivery with typed projection delivery.

An application marks points of its computation with `Projection.publish kind
~key`. A projection kind is a generative descriptor with a wire name, a key
order, a key codec, a value codec, a value equality, and a publication cutoff. A
closed catalog of kinds is fixed at `Root.create`, with one positive
`projection_capacity`.

Each successful commit then produces one immutable `Projection.Commit.t`: one
complete snapshot of every active attachment, and one ordered batch of
`Attached`, `Changed`, and `Removed` updates against the recipient's prior
delivered snapshot. Eta Crux owns identity, incarnation allocation, change
classification, removal, canonical order, and atomic delivery. The driver stays
the only transport writer, and one acknowledgment covers one delivery.

A replaced serialized session receives the driver-retained committed snapshot as
one acknowledged `Bootstrap` on the fresh session. The application owns no
replay and no resynchronization protocol.

The delivered type is:

```ocaml
type Projection.delivery =
  | Updates of Projection.Batch.t
  | Bootstrap of Projection.Snapshot.t
```

## Requirements

In this section, "the system" is the `eta_crux` package, its serialized
transport packages `eta_crux_json` and `eta_crux_sexp` with the vendored wire
common code, and the `eta_crux_test` harness package.

### Package and surface

- The system shall expose one public `Projection` module in `eta_crux.mli` with `Incarnation`, `Kind`, `Catalog`, `Snapshot`, `Batch`, `Commit`, the `delivery` type, the `preflight_error` type, and `publish`. ^crxprj-iczc
- The system shall add no package dependency to `eta_crux` for the projection surface. ^crxprj-oohc
- The system shall keep the projection implementation in private modules of the `eta_crux` package. ^crxprj-oghw

### Projection kinds and catalog

- The system shall fix the wire name, key order, key codec, value codec, value equality, and publication cutoff of a projection kind for the complete lifetime of that kind. ^crxprj-fnj3
- The system shall create one distinct projection kind for each `Kind.define` call, including calls with equal arguments. ^crxprj-0ai1
- The system shall accept an empty kind list in `Catalog.create`. ^crxprj-hohr
- If a kind list contains the same descriptor more than once, then `Catalog.create` shall raise `Invalid_argument`. ^crxprj-bmrc
- If two descriptors in a kind list use the same wire name, then `Catalog.create` shall raise `Invalid_argument`. ^crxprj-zcav
- If a wire name does not match `[a-z][a-z0-9._-]*`, then `Catalog.create` shall raise `Invalid_argument`. ^crxprj-urbd
- If a wire name contains more than 128 bytes, then `Catalog.create` shall raise `Invalid_argument`. ^crxprj-bqd3
- The system shall reject an invalid kind list in `Catalog.create`, before any root exists. ^crxprj-3mtt
- Where one catalog serves several roots, the system shall keep committed state, projection capacity, and incarnation allocation separate for each root. ^crxprj-vtpn
- The system shall accept one `catalog` and one `projection_capacity` in `Root.create` and shall fix both for the root lifetime. ^crxprj-1jit
- If `projection_capacity` is not positive, then `Root.create` shall raise `Invalid_argument`. ^crxprj-c7oo

### Publication

- The system shall return the candidate value of `Projection.publish` to the local computation. ^crxprj-k7i6
- The system shall apply the publication cutoff of a kind to the outward projection image only. ^crxprj-4sl4
- The system shall treat the projection image as the only committed outward value and shall keep the root computation result local. ^crxprj-29xj
- The system shall accept `Exported_endpoint.t` and `Request_export.t` values inside a projection value, and shall deliver committed state and shell capabilities in one atomic image. ^crxprj-x10z
- The system shall require a session-independent projection key as a documented application obligation. ^crxprj-thta

### Projection identity and incarnation

- The system shall define a projection identity as one exact `Kind.t` instance with one key, and shall define key equivalence as `key_compare left right = 0`. ^crxprj-0yei
- The system shall use the `key_compare` relation of a kind for identity, lookup, collision detection, and deterministic order. ^crxprj-h9g9
- The system shall keep at most one active attachment for each projection identity in one final committed image. ^crxprj-wt0g
- If one final committed image contains two active attachments for one projection identity, then the system shall reject the advancement with `Identity_collision`, including a pair with equal values. ^crxprj-qtij
- The system shall continue a retained incarnation only while one structural publication occurrence publishes one projection identity in consecutive committed images. ^crxprj-n6m4
- The system shall end an incarnation when its occurrence becomes absent, when its occurrence re-enters after absence, when its occurrence changes kind, when its key changes to a non-equivalent key, or when another occurrence becomes the owner of that identity. ^crxprj-csat
- When an attachment of the same kind and an equivalent key follows a removal, the system shall start a new incarnation for that projection identity. ^crxprj-5uvd
- When one commit removes one occurrence and attaches a replacement for the same projection identity, the system shall treat the change as a valid replacement with adjacent `Removed` and `Attached` updates. ^crxprj-2qe1
- The system shall allocate each incarnation from one positive unsigned 64-bit root counter and shall treat zero as an invalid incarnation. ^crxprj-grfp
- The system shall keep every allocated incarnation unique for the root lifetime and shall reuse no incarnation value. ^crxprj-022s
- The system shall validate the complete candidate image before it allocates new incarnation values, and shall allocate them in deterministic batch order. ^crxprj-x6h6
- If an advancement fails, then the system shall consume no incarnation value. ^crxprj-hu3l
- If the incarnation counter is exhausted, then the system shall fail the advancement before commit with `Incarnation_exhausted`. ^crxprj-eqkj
- The system shall keep `Projection.Incarnation.t` abstract with `equal` and `compare` only, and shall expose no constructor and no wire representation. ^crxprj-a2lh

### Cutoff and retained values

- When an existing incarnation publishes a candidate that its cutoff suppresses, the system shall keep the prior complete retained value in the committed image and shall emit no `Changed` update. ^crxprj-io2y
- The system shall emit `Attached` and `Removed` updates independent of the publication cutoff. ^crxprj-o1uj
- If a `key_compare` call or a cutoff call raises, then the system shall preserve the prior commit, publish no delivery, and start no post-commit work. ^crxprj-02pk
- If a `key_compare` call or a cutoff call raises, then the system shall record origin `Transition` and trigger `Projection_preflight` and shall retain the local exception cause. ^crxprj-jcmu

### Preflight and capacity

- The system shall bound the active projection identities of the committed image, the update records of one ordinary batch, and the entries of one bootstrap snapshot independently by `projection_capacity`. ^crxprj-ma3z
- The system shall count one replacement as two update records. ^crxprj-ipui
- The system shall chunk, drop, or coalesce no update record to satisfy `projection_capacity`. ^crxprj-0jbu
- The system shall define the preflight error family as exactly `Unknown_kind`, `Identity_collision`, `Projection_capacity_exceeded`, and `Incarnation_exhausted`. ^crxprj-z5gu
- If a preflight error occurs, then `Root.advance` shall return `Failed` with one `Failure.t`. ^crxprj-tcb7
- The system shall return the exact `Projection.preflight_error` from `Failure.Packed_cause.projection_preflight` for a preflight cause, and `None` for every other packed cause. ^crxprj-hwlg
- If a preflight error occurs, then the system shall preserve the prior committed image, emit no delivery, and start no post-commit work. ^crxprj-t5kp
- If a preflight error occurs, then the system shall record origin `Transition` and trigger `Projection_preflight`. ^crxprj-7dej

### Commit, snapshot, and batch

- When an advancement commits, the system shall create one immutable `Projection.Commit.t` that holds one complete snapshot and one ordered update batch. ^crxprj-mhys
- The system shall show an observer the prior complete commit or the new complete commit, and no partial commit. ^crxprj-md57
- The system shall compute a batch from the prior committed snapshot and the final stabilized state only, and shall put no intermediate recomputation into the commit. ^crxprj-htsl
- The system shall include one entry with kind, key, incarnation, and complete retained value for each active attachment of a snapshot. ^crxprj-56ig
- The system shall carry the identity, the new incarnation, and the complete value in `Attached`, the identity, the existing incarnation, and the complete value in `Changed`, and the identity with the ended incarnation in `Removed`. ^crxprj-o4aq
- The system shall produce one of these per-identity batch sequences against the prior delivered snapshot: no update; `Absent` then `Attached`; `Active` then `Changed`; `Active` then `Removed`; or `Active` then `Removed` and `Attached`. ^crxprj-96kb
- The system shall set the incarnation of a `Changed` update and of a `Removed` update to the active incarnation of that identity. ^crxprj-mtx2
- The system shall emit `Attached` only for an absent target state, with a nonzero incarnation that differs from the removed incarnation of a replacement. ^crxprj-9fjf
- The system shall emit at most two updates for one identity in one batch, and shall use adjacent `Removed` then `Attached` as the only two-update sequence. ^crxprj-1fte
- The system shall compute the initial advancement against an empty delivered snapshot and shall emit `Attached` for every active projection. ^crxprj-bto6
- When an initial commit has no active projection, the system shall emit one empty batch. ^crxprj-9h4r
- When a commit succeeds, the system shall create exactly one delivery and shall require exactly one acknowledgment, including a commit with an empty batch. ^crxprj-v93q
- The system shall accept an empty catalog and an empty projection image as valid. ^crxprj-aeuq
- The system shall order snapshot entries, batch updates, and serialized items by catalog declaration order, then by `key_compare` order. ^crxprj-u36h
- The system shall carry one `commit : Projection.Commit.t` and one `post_commit : Post_commit.t` in the `Committed` case of `Root.outcome`. ^crxprj-1gdf
- The system shall expose `Root.t` without an output type parameter. ^crxprj-edzh
- The system shall expose exactly the snapshot and the batch from `Projection.Commit.t`, and no commit identity, revision, delivery state, or terminal state. ^crxprj-8mxg

### Typed read surface

- The system shall define one `('key, 'value) entry` record with the fields `key`, `incarnation`, and `value`. ^crxprj-erna
- The system shall define `('key, 'value) update` as `Attached of entry`, `Changed of entry`, and `Removed of { key; incarnation }`. ^crxprj-zwar
- The system shall return the complete matching entry or `None` from `Snapshot.find_opt` for one kind and one key. ^crxprj-ux42
- The system shall return the ordered update list of one identity from `Batch.find_opt` for one kind and one key. ^crxprj-ukqw
- The system shall fold a snapshot over `Pack : ('key, 'value) Kind.t * ('key, 'value) entry -> packed_entry` values with an accumulator. ^crxprj-n23f
- The system shall fold a batch over `Pack : ('key, 'value) Kind.t * ('key, 'value) update -> packed_update` values with an accumulator. ^crxprj-20xp
- The system shall enumerate both folds in canonical order. ^crxprj-xzh4
- The system shall keep `Projection.Snapshot.t`, `Projection.Batch.t`, `Projection.Commit.t`, and `Projection.Incarnation.t` abstract. ^crxprj-pe2t
- The system shall expose no production query for delivered projection state. ^crxprj-saet
- The system shall define `Projection.delivery` as `Updates of Batch.t` and `Bootstrap of Snapshot.t`. ^crxprj-hdte

### Committed and delivered observation

- The system shall return `Projection.Snapshot.t option` from `Driver.latest_committed_snapshot`, and `None` before the first commit. ^crxprj-4jn2
- The system shall publish the committed snapshot after commit and before delivery, and shall show a concurrent pull the prior complete snapshot or the new complete snapshot. ^crxprj-4duc
- The system shall expose no commit identity, revision, delivery state, or terminal state through the committed pull. ^crxprj-8bfj
- The system shall keep the latest committed snapshot after a failed delivery, after a stop, and after a crash. ^crxprj-bryz
- The system shall perform no delivery work and no post-commit work in a committed pull. ^crxprj-a5pq
- The system shall return the typed `Projection.delivery` from `Driver.Delivery.projection` and the delivery reason from `Driver.Delivery.reason`. ^crxprj-80tl
- The system shall accept exactly one answer for one delivery token. ^crxprj-uk4q
- When a delivery is acknowledged as successful, the system shall admit post-commit work in the same effect. ^crxprj-291b
- The system shall run delivery after commit and before post-commit work, and shall run no adapter callback during stabilization. ^crxprj-z3ry
- If a delivery fails, then the system shall keep the commit published and shall advance no delivered state. ^crxprj-m27l
- If a delivery fails, then the system shall latch `Adapter_delivery` with trigger `Projection_delivery`, discard ordinary post-commit work, start terminal cleanup, and retry nothing. ^crxprj-5sh6
- While a delivery is pending, the system shall keep that delivery through a stop or a crash and shall start terminal work after its answer. ^crxprj-xd9s
- The system shall define `Adapter.delivery` as one record with the fields `projection` and `reason`. ^crxprj-uxyx
- The system shall expose `Driver.t`, `Driver.Binding.t`, `Driver.Delivery.t`, `Driver.event`, `Adapter.resource`, and `Hosted.run` without an output type parameter, and `Binding.serialized` without an `output` codec label. ^crxprj-3jk4
- The system shall retain the latest delivered snapshot in the delivery recipient, shall hold no delivered snapshot before the first accepted delivery, and shall establish an empty delivered snapshot from an accepted empty initial batch. ^crxprj-1uw3
- While a delivery is pending, the system shall keep the prior accepted delivered snapshot in place, and shall advance delivered state for a failed delivery in no case. ^crxprj-1d5m
- The system shall install the complete new observation in the recipient before it acknowledges success. ^crxprj-wam3
- The system shall decode and validate a complete delivery before host mutation and shall install the complete new delivered snapshot as one host-visible transaction. ^crxprj-gc9i
- If installation fails, then the system shall keep the prior delivered state observable and shall make no partial state visible. ^crxprj-1fo8
- The system shall use the failure trigger `Projection_delivery` for every projection-delivery failure and shall expose no `Output_delivery` trigger. ^crxprj-rovw

### Serialized frames and grammars

- The system shall implement exactly one projection protocol profile, changed complete-value batch push, with no negotiation, no fallback, and no dormant tag. ^crxprj-cnaj
- The system shall expose `Projection_deliver of { seq; reason; content }` and `Projection_result of { seq; reply_to; result }` in the public `Wire.Frame.t`, and shall expose no output delivery frame. ^crxprj-sl78
- The system shall define the wire projection entry with the fields `kind`, `key`, `incarnation`, and `value`, the wire projection update as `Attached`, `Changed`, and `Removed`, and the projection content as `Updates` or `Bootstrap`. ^crxprj-boby
- The system shall pair the `Advancement` reason with `Updates` content and the `Session_replacement` reason with `Bootstrap` content, and shall reject any other pairing as an invalid application payload. ^crxprj-qigm
- The system shall encode serialized items in canonical order, and the recipient shall reject any other order and shall sort or repair no sequence. ^crxprj-xh4l
- The system shall set the frame item count to the exact number of encoded items, and the recipient shall reject any other count. ^crxprj-9ome
- The system shall encode an incarnation as a canonical unsigned decimal without a leading zero, and shall reject a zero incarnation. ^crxprj-mxly
- The system shall encode a JSON projection frame with closed objects, the field order `kind`, `key`, `incarnation`, `value`, an `update` field before those fields in a batch, no `value` field in `Removed`, and shall reject unknown, duplicate, missing, and wrongly typed fields. ^crxprj-oot4
- The system shall encode an S-expression projection frame as one flat list with the item count and then the item fields in semantic order, with the update tag first in a batch item and no value atom in `Removed`, and shall reject nesting, extra atoms, and wrong arity. ^crxprj-43y5
- The system shall encode wire bytes as unpadded base64url in both formats and shall reject noncanonical bytes. ^crxprj-ufyv
- The system shall report `accepted` or `failed` for one complete delivery in one `projection.result` frame that references the sequence of its delivery command. ^crxprj-i9wx
- The system shall encode a JSON accepted result with the fields `seq`, `tag`, `reply_to`, and `outcome`, and a JSON failed result with those fields and `message`. ^crxprj-ujwi
- The system shall encode an S-expression result as `(seq projection.result reply-to accepted)` or `(seq projection.result reply-to failed message-bytes)` with the diagnostic in unpadded base64url. ^crxprj-4i0y
- The system shall carry a redacted UTF-8 diagnostic of at most 1,024 bytes in a failed result, shall close the session for a longer or invalid diagnostic, and shall truncate no diagnostic. ^crxprj-ocex
- The system shall keep one independent unsigned 32-bit sequence for each direction and shall consume one sequence for each command and each result. ^crxprj-bl0a

### Payload rejection, structural errors, and bounds

- If a projection payload contains an unknown kind, an invalid or noncanonical key, a zero incarnation, items outside canonical order, duplicate snapshot identities, an invalid update transition, a codec error, or more entries than the recipient projection capacity, then the recipient shall return `projection.result failed` and shall keep the session open. ^crxprj-xgql
- The system shall validate every update transition of a batch against the prior delivered snapshot of the recipient, and shall validate the item count. ^crxprj-cyq1
- If a delivery exceeds the recipient projection capacity, then the recipient shall fail the complete delivery atomically and shall apply no fallback. ^crxprj-vkn6
- If a malformed envelope, a bad frame sequence, a bad result correlation, or an invalid result diagnostic occurs, then the system shall close the session. ^crxprj-ytcu
- The system shall keep `max_frame_bytes` positive and explicit and shall apply it before frame decode and after frame encode. ^crxprj-u0u6
- If a projection delivery frame exceeds `max_frame_bytes`, then the system shall close the session with `Frame_too_large`, fail the delivery, and split or truncate no payload. ^crxprj-gbs2
- The recipient shall decode each wire key, encode it again, require byte equality, and use `key_compare` to detect duplicate identities. ^crxprj-ueje

### Codec obligations and encoding failures

- The system shall require of a key codec that equivalent keys either both encode or both return an encode error, that successful encodings of equivalent keys are byte-equal, that successful encodings of non-equivalent keys differ, and that decoding encoded bytes returns an equivalent key. ^crxprj-ql9u
- The system shall require of a value codec that decoding an encoded value returns a value equal under `value_equal`. ^crxprj-da2s
- The system shall require of a kind that `key_compare` is a stable total order. ^crxprj-b3gd
- If key encoding returns an encode error, then the system shall fail the serialized delivery before it creates a wire identity and shall keep the committed typed identity unchanged. ^crxprj-8047
- If a key codec or a value codec returns an encode error after commit, then the system shall keep the commit published and shall fail the complete delivery as `Adapter_delivery` with trigger `Projection_delivery`. ^crxprj-oazz
- If a codec raises, then the system shall retain the local exception cause and shall convert the defect into no typed codec error. ^crxprj-v0ie
- The system shall put no local encoding diagnostic into a frame. ^crxprj-b30d
- The system shall build or update the committed export registry after commit and shall then run projection value codecs inside the existing remote-handle encoding fence. ^crxprj-xm6p
- If a value codec requests a handle for an export that is absent from the committed registry, then `remote_handle` shall raise, the commit shall stay published, and the delivery shall fail as `Adapter_delivery`. ^crxprj-bejf
- Where the binding is the identity binding, the system shall carry typed exported endpoints and request exports directly, shall run no codec, and shall allocate no remote handle. ^crxprj-k9x3
- The system shall write transport frames from the driver only. ^crxprj-vii3
- The system shall exchange no catalog, no catalog fingerprint, and no codec metadata, and shall take the peer catalog and capacity configuration from separate configuration. ^crxprj-yvmd
- The system shall own the catalog and the projection capacity in the root and shall read both from the root in the attached driver. ^crxprj-sbyz

### Session replacement and bootstrap

- The system shall build a bootstrap from the driver-retained latest committed snapshot in canonical order, and shall perform no stabilization, no commit, and no application replay for a replacement. ^crxprj-h935
- The system shall preserve active incarnation values across session replacement. ^crxprj-44kq
- The recipient shall install a bootstrap as one atomic replacement of its complete delivered snapshot, and shall leave the delivered state of an identity that the bootstrap does not contain. ^crxprj-kr1l
- When a replacement is accepted, the system shall run preflight, fresh identity registration, bootstrap encoding against the fresh registry, old-session closure, bootstrap send, permit settlement, and the result wait with fence lift, in that order. ^crxprj-19o8
- The system shall send the bootstrap as the first delivery of a new session and shall send every later advancement batch after it in order. ^crxprj-aiag
- The system shall define the replacement preflight family as exactly `Starting`, `Replacement_pending`, `Awaiting_delivery`, `Terminating`, and `Closed`. ^crxprj-ogzt
- While a delivery is unacknowledged, the system shall reject a replacement with `Awaiting_delivery`. ^crxprj-yq72
- If a replacement is requested on an identity binding, then the system shall return `Closed`. ^crxprj-f4pe
- While the driver holds no committed image, the system shall reject a replacement with `Starting`, and after an initial commit with an empty image it shall accept a replacement with an empty bootstrap. ^crxprj-pc3u
- If a commit occurs while no session is live, then the system shall publish the commit, fail the delivery immediately, latch `Adapter_delivery`, and crash the root. ^crxprj-2u5g
- While the driver is running with committed state and no live session, the system shall accept a replacement as the recovery path. ^crxprj-noqf
- The system shall wait for no in-flight post-commit effect during a replacement and shall admit no post-commit work for a bootstrap. ^crxprj-crsj
- The system shall define the replacement outcome family as exactly `Replaced`, `Stopped`, and `Crashed of Failure.t`. ^crxprj-kipf
- If a bootstrap result is `failed`, or if the new session is lost during bootstrap delivery, then the system shall latch `Adapter_delivery` with trigger `Projection_delivery`, return `Crashed`, and retry nothing. ^crxprj-wkgm
- While the system waits for a bootstrap result, a root stop shall return `Stopped`, a root crash shall return `Crashed` with the root failure, and terminal work shall wait for the pending answer. ^crxprj-eyav
- The system shall arbitrate commit and replacement by first winner at driver-operation granularity, and shall carry the prior complete committed snapshot or the new complete committed snapshot in the bootstrap. ^crxprj-2oyz
- The system shall run advancement only in driver state `Running` and shall run no advancement while a replacement delivery is pending. ^crxprj-v087
- The system shall bound the bootstrap entry count by `projection_capacity` and shall add no preflight failure for a replacement. ^crxprj-jmdc
- If a bootstrap frame exceeds `max_frame_bytes`, then the system shall close the new session with `Frame_too_large`, fail the delivery, latch `Adapter_delivery`, and return `Crashed`. ^crxprj-slkt
- The system shall send no bootstrap on an initial session attach and shall use the `Attached` advancement of the first commit as the starting observation of that session. ^crxprj-jubd

### Test harness and verification artifacts

- The system shall supply a projection harness in `eta_crux_test` with a scripted delivery responder, write-failure injection, adapter-failure injection, codec-failure injection, a replacement trigger, session-loss injection, an incarnation-counter seed, and capacity-pressure helpers, for both bindings. ^crxprj-rndm
- The harness responder shall answer each delivery at most once and shall fail the test on a second answer. ^crxprj-yw13
- While a harness delivery is held, the system shall admit no post-commit work. ^crxprj-3hd9
- The test handle shall expose the committed snapshot through the production driver and one test-only delivered-state shadow at successful delivery, and shall use that shadow for test injection. ^crxprj-7i6u
- The recording adapter shall record each accepted projection delivery. ^crxprj-zieq
- The system shall carry the new PRJ, PRW, and PRB registry rows, the new H-09 to H-11 rows, and the amended output-delivery rows in `docs/design/eta-crux-v1/semantic-laws.md`, in the same change as the `.mli` prose that states their laws. ^crxprj-cj3l
- The system shall produce equivalent typed observations on the identity binding and the serialized binding for equivalent scripts, at the adapter delivery log, the committed pull, the delivered shadow, and the driver outcomes. ^crxprj-2xu1
- Each projection race gate shall control both legal winners and shall end with an available empty fiber census. ^crxprj-r3mt
- The system shall describe the projection surface in `public-api.md`, the single projection profile in `wire-protocol.md`, the registered gates in `verification.md`, and the capability overview in the Eta Crux design `README.md`. ^crxprj-f5zb
- The system shall keep only the fixed telemetry names, categories, and redacted attributes of `verification.md`, with projection vocabulary in place of output vocabulary. ^crxprj-fox3
- The system shall keep the `CONTEXT.md` projection glossary consistent with the delivered surface. ^crxprj-dgb7
- The system shall contain no snapshot-push frame, no pull notification, no pull cursor, and no paging machinery. ^crxprj-v5b5

## Implementation Decisions

Provenance: the approved design package under
[`docs/wayfinder/eta-crux-typed-projection-delivery/`](../../wayfinder/eta-crux-typed-projection-delivery/map.md).
The normative sources are [Commit observation and ownership
contract](../../wayfinder/eta-crux-typed-projection-delivery/issues/09-commit-observation-and-ownership-contract.md),
[Identity, codec, and wire
contract](../../wayfinder/eta-crux-typed-projection-delivery/issues/10-identity-codec-and-wire-contract.md),
[Session replacement and
bootstrap](../../wayfinder/eta-crux-typed-projection-delivery/issues/11-session-replacement-and-bootstrap.md),
[Laws and deterministic test
controls](../../wayfinder/eta-crux-typed-projection-delivery/issues/12-laws-and-deterministic-test-controls.md),
[Select the public interface and
seam](../../wayfinder/eta-crux-typed-projection-delivery/issues/14-select-public-interface-and-seam.md),
[Implementation
plan](../../wayfinder/eta-crux-typed-projection-delivery/issues/15-implementation-plan.md),
and [Exact projection read and delivery
signatures](../../wayfinder/eta-crux-typed-projection-delivery/issues/18-exact-projection-read-and-delivery-signatures.md).

**One atomic change.** This is change 2 of the plan. It lands as one semantic
change. There is no intermediate green state that still delivers root output.
[Fallible codec](01-fallible-codec.md) lands first and the baseline is recorded
between the two.

**Ownership seam is unchanged.** Eta Crux owns stabilization, atomic commit,
delivery order, serialized sessions, and delivery acknowledgment. Applications
own state. The driver is the only transport writer.

**Public read surface.** The exact signatures are fixed:

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

module Snapshot : sig
  type t

  val find_opt :
    ('key, 'value) Kind.t -> key:'key -> t -> ('key, 'value) entry option

  type packed_entry =
    | Pack : ('key, 'value) Kind.t * ('key, 'value) entry -> packed_entry

  val fold : t -> init:'acc -> f:('acc -> packed_entry -> 'acc) -> 'acc
end
```

`Batch` has the same shape with `('key, 'value) update list` from `find_opt` and
`packed_update` in its fold. `Commit` exposes `snapshot` and `batch` only.
Neither container exposes `length` or `is_empty`; the fold covers counting. The
GADT pack form matches `Kind.packed` and `Host_operation.packed`; a rank-2 record
of polymorphic functions was rejected.

**Entries are read views.** `entry` and `update` are concrete, but the containers
are abstract and a caller cannot construct an incarnation, so caller-built values
grant no authority. The typed shapes mirror the wire shapes one to one.

**Incarnation representation.** The wire field is `int64` with a documented
unsigned 64-bit contract, encoded as canonical unsigned decimal. No abstract
`uint64` type is added. Zero is invalid, and `Incarnation_exhausted` fires as a
preflight error before the practical range matters.

**Wire naming.** The public frames reuse the existing `delivery_reason` and
`delivery_result` types. `projection_reason` and `projection_result` stay the
semantic-level names of the wire contract.

**Projection and endpoint stay separate concepts.** They may share private
structural registration machinery. They share no identity, admission, capacity,
acknowledgment, or remote handle. There is no projection remote handle: a
serialized item carries the kind wire name, the encoded key, and the
root-lifetime incarnation.

**Module map.**

- `lib/crux/eta_crux.mli` with new `Projection`, changed `Root`, `Driver`,
  `Adapter`, `Hosted`, `Wire.Frame`, and `Failure.trigger_kind`.
- New private `lib/crux/crux_projection.ml` and `.mli` for kinds, catalog,
  incarnation allocation, preflight, cutoff application, update
  classification, canonical order, and snapshot retention. Seam edits in
  `crux_root.ml` and `crux_engine.ml`.
- `crux_driver.ml` and `crux_driver_base.ml` for the delivery fences and
  `latest_committed_snapshot`.
- `crux_driver_serialized.ml` for canonical-order encoding, frame bounds, result
  correlation, the payload-rejection and structural split, the export-registry
  fence, and the seven-step replacement sequence.
- `lib/crux_wire_common/protocol_model.ml` and `frame_conversion.ml`,
  `lib/crux_json/protocol.ml`, `lib/crux_sexp/protocol.ml`, and
  `lib/crux/crux_wire.ml` for the frames and grammars.
- `crux_failure.ml`, `crux_portable_failure.ml` for the `Projection_delivery`
  trigger; portable byte 11 is remapped with no format shim.
- `lib/crux_test`: new projection harness, delivered-state shadow in
  `crux_test_handle.ml`, projection recording in `crux_recording_adapter.ml`.
- `docs/design/eta-crux-v1/`: `semantic-laws.md`, `public-api.md`,
  `wire-protocol.md`, `verification.md`, `README.md`.

**Compile-time migrations.** `Root.create` gains `catalog:` and
`projection_capacity:`; the output type parameter disappears from `Root.t`,
`Driver.t`, `Driver.Binding.t`, `Driver.Delivery.t`, `Driver.event`,
`Adapter.resource`, `Adapter.delivery`, and `Hosted.run`; `Binding.serialized`
loses `output:` because codecs live in kinds; `latest_committed_output` becomes
`latest_committed_snapshot`; `Delivery.output` becomes `Delivery.projection`;
`Root.outcome Committed` carries the commit.

**Deletions.** The output delivery frames with their JSON and S-expression
codecs, the `Output_delivery` trigger, the output-delivery bench workloads, and
every output-only gate body. The rejected profiles are deleted by omission: rows
PRW-21 and PRW-23 to PRW-29 are never written. No compatibility path, no shim,
no dormant tag.

**Registry amendments.** T-03, T-04, D-02, D-03, D-07, D-08, D-09, O-01, O-02,
F-04, F-05, W-01 to W-04, W-06 to W-08, W-10, plus the vocabulary sweep over
C-05, T-02, GTC-14, GTC-18, RST-05, POLL-01, POLL-07, and H-08. Three gates are
renamed because their observation boundary changed:
`qcheck_complete_output_per_commit` to `qcheck_projection_image_per_commit`,
`qcheck_latest_committed_output` to `qcheck_latest_committed_snapshot`, and
`test_handle_output_boundaries` to `test_handle_projection_boundaries`.

**Affected packages.** `eta_crux`, `eta_crux_json`, `eta_crux_sexp`,
`eta_crux_test`, `test/crux/*`, and a compile-only migration of
`lib/crux/bench/bench_eta_crux.ml`. The root `eta` package is untouched, and no
`drivers/` package consumes `eta_crux`.

## Testing Decisions

A good test observes the public seam: what the adapter received, what the peer
decoded, what the committed pull returns, what the delivered shadow holds, and
what `Root.advance` or the driver returned. It asserts nothing about the private
projection store.

**Seams** (unchanged from the design package; no new seam is introduced):

1. **Adapter delivery log** on the identity binding, through
   `Eta_crux_test.Handle` and the recording adapter. This is the primary typed
   observation of batches and bootstrap snapshots.
2. **Wire peer frame log** on the serialized binding, through the existing
   session peer. This is the only frame-level seam.
3. **Committed pull**: `Driver.latest_committed_snapshot`.
4. **Delivered shadow**: the test-only delivered state of the test handle. It is
   the seam for delivered-state laws, and it is the reason no production query
   exists.
5. **Post-commit observer**: staged, started, settled, and discarded events, for
   acknowledgment-fence laws.
6. **Driver outcomes**: `Root.advance` results, driver results, and
   `Failure.Packed_cause` projections.
7. **Session peer state**: open or closed, with sequence positions.

**Gate schedule.** Every registry row has one named gate. The complete row-to-gate
map is the gate schedule of the [implementation
plan](../../wayfinder/eta-crux-typed-projection-delivery/issues/15-implementation-plan.md).
Test groups: `test/crux/unit` for deterministic cases, `test/crux/laws` for
generated properties, `test/crux/races` for two-winner races, `test/crux/wire`
for frame matrices and malformed input, `test/crux/conformance` for
`conformance_projection_transport_equivalence`, `test/crux/telemetry` for the
fixed observation contract, and `test/crux/negative` for the opacity compile
gates.

**Property discipline.** Each generated gate states its generated class and its
discriminating coverage. Named classes include: descriptor lists with one
injected catalog violation covering all four rejection classes plus acceptance;
structural sequences that discriminate all five incarnation endings; batches with
suppress-always cutoffs and replacements; capacity populations at the exact
boundary and one over per dimension; entry permutations for order rejection;
count-mismatch injection; frame sizes around `max_frame_bytes`; and one payload
violation per generated batch covering all eight rejection classes. Opacity
(`PRJ-15`, `PRJ-27`, `PRJ-30`) is enforced by absence from the `.mli` plus the
re-run negative suite.

**Race discipline.** `race_commit_atomicity`,
`race_commit_vs_crash_both_winners`, `race_terminal_vs_delivery`,
`race_pull_vs_commit_both_winners`, and `race_session_replacement` are amended;
`race_replacement_vs_commit_both_winners` is new. Each controls both legal
winners and finishes with an empty fiber census. Deterministic outcomes stay
ordinary gates: replacement during a pending delivery, a commit with no live
session, and replacement in the loss window.

**Inherited gaps closed here.** Three D-07 terminal pull gates, the five
`test_replace_error_*` gates, and `test_session_replacement_permit_wait`.

**Prior art.** `test/crux/laws/test_eta_crux_laws.ml` for registry-backed
properties, `test/crux/races/test_eta_crux_races.ml` for barrier-driven races,
`test/crux/conformance/test_eta_crux_conformance.ml` for the identity and
serialized equivalence pattern, and `test/crux/wire/test_eta_crux_wire.ml` for
grammar matrices.

## Out of Scope

- Performance workloads, counters, and PRF rows. They belong to [Projection
  performance gates](03-projection-performance-gates.md).
- The fallible `Codec` migration. It belongs to [Fallible
  codec](01-fallible-codec.md) and lands first.
- Application-specific projection values and rendering policy.
- Application-owned replay, revision, or resynchronization protocols.
- A compatibility shim for the output-delivery interface.
- A snapshot-push profile, a notification-then-pull profile, cursors, and paging.
  A future pull profile is a fresh effort.
- Transport writers outside the driver.
- An `eta_schema` integration package for projection codecs.

## Further Notes

Five risks were presented and accepted as policy at [design package
approval](../../wayfinder/eta-crux-typed-projection-delivery/issues/17-design-package-approval.md):
the breaking change carries no compatibility path; change 2 has no intermediate
green state that keeps output delivery; performance gates stay regression-only;
the `int64` incarnation keeps a documented contract instead of a distinct type;
and the deleted profiles stay deleted by omission.

Application obligations that no runtime gate can prove for arbitrary types:
projection keys must be session-independent, and they must contain no
`Exported_endpoint.t` and no `Request_export.t`. Generated gates prove the codec
and comparator laws for every codec and comparator that the suite uses.
