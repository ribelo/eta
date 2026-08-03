# Wire codec and protocol contract

Type: prototype
Status: resolved
Blocked by: 13, 16

## Question

What wire contract carries exported endpoint invocations and host operations
between an Eta Crux core and a shell in another process or language?

Decide and prototype:

- the payload codec abstraction and its error type.
- schema ownership, protocol tags, and versioning.
- envelope session, sequence, and correlation fields.
- endpoint invocation, request resolution, cancellation, and revocation.
- size limits, malformed input, unknown tags, and duplicate messages.
- whether one format is fixed or selected by a transport package.
- whether V1 needs generated foreign-language types.
- which protocol details remain invisible to application computations.

Use one serialized loopback and one second-language fixture. Do not serialize
closures, local endpoints, graph structure, models, or complete internal action
types.

## Answer

### Boundary

Eta Crux defines one semantic frame type for the complete serialized driver
contract. JSON and S-expression codecs encode the same frame type. A transport
selects one codec when it creates a serialized session.

The frame protocol carries:

- committed root-output delivery and its result;
- portable crash notification and its result;
- exported endpoint invocation and its result;
- inbound request start and its result;
- outbound host-operation dispatch and its result;
- request resolution, cancellation, and terminal notification.

The protocol does not carry models, graph structure, closures, local endpoints,
or complete internal action types. An adapter-defined output codec encodes only
the canonical root output required by its foreign shell.

Local identity transport uses typed OCaml values. It allocates no wire frame,
sequence, token, or encoded payload.

### Payload codecs and host operations

The payload codec remains the small contract from [Exported endpoint and handle
contract](16-exported-endpoint-contract.md):

```ocaml
module Codec : sig
  type decode_error = { message : string }
  type 'a t

  val make :
    encode:('a -> bytes) ->
    decode:(bytes -> ('a, decode_error) result) ->
    'a t
end
```

`encode` is total. `decode` returns one local diagnostic message. Remote results
report only `malformed_payload` and never carry this message.

A host operation is one typed descriptor:

```ocaml
module Host_operation : sig
  type ('request, 'response) t
  type packed = Pack : ('request, 'response) t -> packed

  val define :
    name:string ->
    request:'request Codec.t ->
    response:'response Codec.t ->
    ('request, 'response) t
end
```

The integration binds this descriptor to a typed `Requester.t`. Application
computations receive the requester. They do not receive its name or codecs.

The operation name selects the foreign-shell decoder, encoder, and handler. It
uses `[a-z][a-z0-9._-]*`, contains at most 128 bytes, and is unique within one
adapter binding. Duplicate names fail binding construction.

This open descriptor set replaces a required application-wide effect union.
It also avoids a registration handshake and transport channel per operation.

Applications and integrations own payload schemas. Eta Crux owns frame tags,
framework outcomes, token syntax, and sequencing. Eta Crux generates no foreign
language types.

### Session and envelope

The active transport binding identifies the serialized session. A frame has no
session field. Opaque handles and request tokens authenticate their own session.

The protocol has no version field, negotiation, schema fingerprint, fallback
decoder, or compatibility branch. Both peers must implement the exact current
contract.

Each direction has an independent unsigned 32-bit sequence. The first sequence
is zero. Every frame, including a result or notification, consumes one sequence.

The receiver accepts only the exact next sequence. A duplicate, gap, or exhausted
sequence closes the session. The protocol has no retry, reorder, replay,
resumption, or sequence reset.

Every command result contains `reply_to`. This field contains the peer sequence
of its command. The result tag must match that command family.

A result for an unknown command or the wrong command family is a structural
protocol error. The session retains only pending command sequences and expected
result families.

### Frame families

The command and result pairs are:

| Command | Result | Direction |
|---|---|---|
| `output.deliver` | `output.result` | core to shell |
| `crash.notify` | `crash.result` | core to shell |
| `endpoint.invoke` | `endpoint.result` | shell to core |
| `request.start` | `request.start_result` | shell to core |
| `request.dispatch` | `request.dispatch_result` | core to shell |
| `request.resolve` | `request.resolve_result` | shell to core |
| `request.cancel` | `request.cancel_result` | shell to core |

`output.deliver` carries `advancement` or `session_replacement` as its reason.
Its result reports `accepted` or `failed`. A failed result carries one bounded,
redacted diagnostic string.

The serialized adapter maps `accepted` to `Driver.Delivery.delivered`. It maps a
failed result to `Driver.Delivery.failed`. The existing delivery fence controls
post-commit work and session replacement.

`crash.notify` carries a framework-owned portable projection of `Failure.t`.
The projection preserves origin, trigger, observation position, redacted
snapshots, and each portable Eta cause tree. It contains no hidden typed error.

Its result reports `accepted` or `failed`. A failed crash callback follows the
existing `Crash_handler` evidence rule.

`request.dispatch` carries a request token, host-operation name, and request
payload. `accepted` means that the shell installed response and cancellation
paths. `failed` produces `Requester.Dispatch_failed`.

An unknown host-operation name produces a failed dispatch. It does not close the
session or become an application response.

`request.resolved` and `request.closed` are core-to-shell terminal notifications
for inbound requests. They consume sequences but require no peer acknowledgment.
Transport acceptance completes the driver handoff.

`request.closed` carries one settled closure reason. It carries no Eta cause,
cell identity, graph path, or model data.

### Closed outcomes

Each result frame owns one closed outcome algebra. There is no generic `ok`,
`error`, or global protocol-error wrapper.

`endpoint.result` contains one outcome:

- `accepted`;
- `full`;
- `ingress_closed`;
- `malformed_handle`;
- `unknown_handle`;
- `stale_handle`;
- `revoked_handle`;
- `malformed_payload`.

These cases preserve handle validity, ingress capacity, and ingress closure as
separate layers.

`request.start_result` contains one outcome:

- `started`, with a new request token;
- `request_capacity_full`;
- `ingress_capacity_full`;
- `ingress_closed`;
- `malformed_handle`;
- `unknown_handle`;
- `stale_handle`;
- `revoked_handle`;
- `malformed_payload`;
- `closed`, with one request closure reason.

`request.dispatch_result` contains `accepted` or `failed`.

`request.resolve_result` contains one outcome:

- `accepted`;
- `not_pending`;
- `malformed_request`;
- `unknown_request`;
- `stale_request`;
- `malformed_payload`.

`request.cancel_result` contains the same request-identity outcomes. It omits
`malformed_payload` because cancellation carries no application payload.

Terminal request slots retain `not_pending` until reuse. Reuse increments the
generation. An older token then produces `stale_request`.

### Revocation

The protocol has no standalone export-revocation frame. Committed root output
removes the exported value before the shell can invoke it as current output.

The core registry still enforces the active-interval contract. A current
tombstone produces `revoked_handle`. Slot reuse makes the old handle stale.

This rule avoids a second export-lifecycle channel. Output reconciliation and
authenticated invocation remain the only shell observations.

### JSON and S-expression encodings

JSON uses one object per frame. `seq` and `tag` are required. Bytes use unpadded
base64url text.

The encoder uses the normative field order. A decoder does not depend on JSON
object-field order. It rejects duplicate, unknown, missing, and incorrectly
typed fields.

The S-expression encoding uses one flat list per frame. The first atoms are the
sequence and tag. Remaining atoms use the semantic field order.

Bytes and arbitrary diagnostic text use unpadded base64url atoms. The decoder
rejects nested lists, extra atoms, missing atoms, and unknown tags.

Both decoders reject noncanonical byte encodings. Both codecs produce the same
semantic frame type and protocol errors.

JSON and S-expressions are the two exact encodings. A transport selects one
through configuration. The peers do not negotiate the choice.

### Bounds and malformed input

Each transport requires a positive `max_frame_bytes`. The bound applies before
decoding and after encoding. Eta Crux provides no default or unbounded mode.

An opaque handle or request token contains at most 64 raw bytes. The internal
authenticated token layout remains private to Eta Crux.

A structural protocol error is one of:

- an oversized frame;
- malformed JSON or S-expression syntax;
- an unknown frame tag;
- duplicate, unknown, missing, or incorrectly typed fields;
- invalid or noncanonical base64url text;
- an invalid operation name;
- a bad sequence;
- an unknown `reply_to` value;
- a result from the wrong command family;
- sequence exhaustion.

A structural protocol error closes the session without a protocol reply. The
session settles bound requests with `Session_closed`. Session closure does not
crash the root.

Operation rejection uses its command-specific result and keeps the session open.
Malformed handles, payloads, and request tokens enqueue no application action.

Payload decoder exceptions remain defects. Export decoder defects use
`Export_dispatch`. Host-operation and output codec defects use the existing
request-dispatch and adapter-delivery failure origins.

### Visibility and ownership

Application computations see typed root output, endpoints, requesters, and
responders. They do not see frames, sequences, tokens, encodings, operation
names, transport limits, or protocol errors.

Eta Crux core owns semantic frames, pending correlation, token authentication,
operation outcomes, and session closure effects.

An integration owns host-operation descriptors and the root-output codec. A
transport adapter owns complete frame I/O and selects JSON or S-expressions.

The final package-boundary decision can place these modules without changing
their ownership or semantics.

### Prototype evidence

The selected prototype is on branch `prototype/eta-crux-wire-protocol` at commit
`6d475347`:

- [prototype](https://github.com/ribelo/eta/tree/6d475347/.scratch/prototypes/eta-crux-wire-protocol)
- [wire contract](https://github.com/ribelo/eta/blob/6d475347/.scratch/prototypes/eta-crux-wire-protocol/WIRE.md)
- [public surface](https://github.com/ribelo/eta/blob/6d475347/.scratch/prototypes/eta-crux-wire-protocol/public_surface.mli)
- [results](https://github.com/ribelo/eta/blob/6d475347/.scratch/prototypes/eta-crux-wire-protocol/RESULTS.md)
- [TypeScript fixture](https://github.com/ribelo/eta/blob/6d475347/.scratch/prototypes/eta-crux-wire-protocol/typescript_fixture.ts)

The prototype round-trips 45 representative semantic frames through JSON and
S-expressions. This set covers each frame family and each closed result outcome.

It rejects duplicate sequences, wrong result families, oversized frames,
unknown tags, duplicate fields, and unknown fields. The complete loopback passes
under OxCaml. The OCaml frame matrix also passes under upstream OCaml 5.4.1.

The handwritten TypeScript fixture accepts committed output, acknowledges it,
dispatches `fs.read`, and resolves the request. The OCaml receiver finishes with
no pending command.

### Rejected alternatives

Eta Crux does not require a global effect union, generated foreign types, numeric
operation registration, or one channel per host operation.

It does not add protocol versions, negotiation, fingerprints, unknown-field
tolerance, replay, or compatibility decoding.

It does not put a session identifier in every frame. It does not add a second
correlation identifier beside sequences and request tokens.

It does not use one generic reply frame or one catch-all wire error. It does not
send raw decoder diagnostics to a peer.
