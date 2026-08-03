# Exported endpoint and handle contract

Type: prototype
Status: resolved
Blocked by: 05, 07, 11

## Question

What is the exact transport-neutral contract for exposing a typed local
endpoint to a shell?

Prototype one local identity transport and one serialized loopback transport.
Decide:

- the public shape of `Exported_endpoint.t` and codec attachment.
- whether export is a computation node or an adapter operation.
- stable export identity across recomputation.
- activation, revocation, tombstones, and same-structure re-entry.
- session-scoped generational remote handles.
- the core-side registry and its existential codec packaging.
- how `Endpoint.contramap` narrows the remotely accepted payload.
- errors for unknown, stale, malformed, revoked, full, and closed invocations.
- whether local transport performs any remote-handle lookup or encoding.

The shell must not receive an internal graph path, machine identifier, complete
action protocol, closure, or type witness. Local and serialized invocation must
enqueue the same typed message.

Core endpoint admission returns only `Ingress_closed`. A nonblocking exported
invocation also needs a capacity result. This ticket must keep transport and
handle failures distinct from both results.

## Answer

### Public export surface

An export is a structural computation node. Its public surface is:

```ocaml
module Exported_endpoint : sig
  type 'a computation := 'a t
  type 'payload t

  module Codec : sig
    type decode_error = { message : string }
    type 'payload t

    val make :
      encode:('payload -> bytes) ->
      decode:(bytes -> ('payload, decode_error) result) ->
      'payload t
  end

  type availability_error =
    | Stale
    | Revoked

  type capacity_error = Full
  type admission = (unit, Endpoint.admission_error) result
  type try_result = (admission, capacity_error) result

  val create :
    'payload Endpoint.t computation ->
    codec:'payload Codec.t ->
    'payload t computation

  val try_invoke :
    'payload t ->
    'payload ->
    (try_result, availability_error) result
end
```

`Codec.encode` is total. `Codec.decode` reports a local diagnostic message.
Remote responses report only `Malformed_payload` and never send this message.

The application calls `Endpoint.contramap` before `Exported_endpoint.create`.
The codec payload type must equal the narrowed endpoint payload type.

The registry never receives the complete target action protocol. It receives no
mapping function beyond the one already closed inside the narrowed endpoint.

### Identity and binding

Each export node has one stable structural identity. Each committed active
interval has one generation.

Recomputation during an active interval keeps the generation. It updates the
committed endpoint binding behind retained local values and remote handles.

The codec is fixed for the export node. A different payload contract requires a
different structural export.

Committed structural presence activates an export. Committed absence revokes
the current generation.

Re-entry at the same structural position creates a new generation. A retained
local value returns `Revoked` before re-entry and `Stale` after re-entry.

Registry activation and revocation belong to the atomic structural commit. A
new handle is active before the adapter receives its output.

A removed handle is revoked before the shell observes its removal. Adapter
delivery and post-commit work do not own export lifetime.

Invocation acquires a per-export dispatch permit under the root lock. The permit
pins the session, export generation, and endpoint binding.

If invocation wins, rebinding and revocation wait for permit release. A later
commit can make the queued endpoint incarnation stale before advancement.

If structural commit wins, permit acquisition observes the new binding,
`Revoked`, or `Stale`. It runs no application callback.

### Local identity transport

Local `try_invoke` is synchronous and never waits for queue capacity. It acquires
a dispatch permit before it runs the narrowed endpoint mapper.

The mapper runs without the root lock. Final queue admission uses the binding
that the permit pins.

The local path performs no handle allocation, lookup, encoding, or decoding. It
does not create a serialized registry.

Local and serialized invocation call the same typed queue-admission operation
after serialized boundary work finishes.

### Root ingress queue

The root owns one bounded ingress queue for application actions:

```ocaml
val Root.create :
  ingress_capacity:int ->
  'output description ->
  'output Root.t
```

`Root.create` raises `Invalid_argument` when `ingress_capacity <= 0`. There is no
default or unbounded root-ingress mode.

`Endpoint.send` waits for queue capacity. It returns only
`Endpoint.Ingress_closed` as a typed framework error.

`Exported_endpoint.try_invoke` does not wait. Its nested result preserves export
availability, queue capacity, and endpoint admission as separate layers.

The root uses `Eta.Queue.bounded`. Eta adds synchronous queue operations:

```ocaml
val Queue.try_offer_now :
  ('value, 'error) Queue.t ->
  'value ->
  'error Queue.offer_result

val Queue.poll_now :
  ('value, 'error) Queue.t ->
  ('value, 'error) Queue.poll_result
```

`Queue.Enqueue.try_offer_now` provides the same operation through an enqueue
view. `Queue.Dequeue.poll_now` provides synchronous dequeue through a dequeue
view.

These operations use the existing queue lock and admission policy. `poll_now`
admits waiting senders through the existing FIFO order.

Eta Crux maps queue results as follows:

- `Sent` becomes `Ok (Ok (Ok ()))`.
- `Full` becomes `Ok (Error Full)`.
- `Closed` becomes `Ok (Ok (Error Ingress_closed))`.

`Dropped` and `Closed_with_error` are impossible for the root queue. Either
result is an internal invariant defect.

Waiting `Endpoint.send` calls retain the FIFO priority from Eta Queue. A later
nonblocking invocation cannot overtake them and returns `Full`.

Ingress capacity counts application actions only. Start, stop, crash, and other
internal control events use a separate control lane.

Root ingress closure uses immediate queue shutdown. It drops buffered actions
and wakes waiting endpoint senders with `Ingress_closed`.

An export can remain structurally active after ingress closes. A valid invocation
then returns nested `Ingress_closed` until revocation or session closure wins.

### Serialized session and handles

A serialized driver owns at most one active shell session. Replacement closes
the old session before it installs the new session.

Each session owns one registry and a unique session value. The serialized driver
owns the authentication context across its session sequence.

A remote handle is an opaque authenticated token for its session, slot, and
generation.

The token exposes no graph path, cell identity, endpoint identity, action
protocol, closure, or type witness.

Revocation leaves a tombstone in the current slot. Revoked slots are immediately
available for reuse.

Reuse increments the slot generation. The old handle then becomes stale.
Registry storage follows peak slot use instead of total historical exports.

Live replacement runs as one root administration transaction. It is eligible
only while the root is ready and has no pending post-commit batch.

The transaction closes the old session, snapshots all active exports, populates
the new registry, installs the new session, and returns current output.

Session closure first marks the old session as closing. This mark rejects new
permits. The administration transaction then waits for existing session permits.

The root administration phase blocks structural commits during this wait. It
does not hold the root lock while callbacks finish.

If a permitted callback latches root crash, the crash aborts replacement after
all permits settle. Eta Crux closes the candidate registry and installs no
session.

The aborted replacement suppresses current-output delivery. The root continues
through the ordinary crash-detection and teardown path.

The driver delivers this output through the new session. Session installation
and structural commit use the same root lock and cannot interleave.

The new session becomes active only after its registry is complete. Every active
export receives a fresh handle for the new session.

The driver must deliver the returned output before the next advancement. The
root retains a session-delivery fence until the driver acknowledges delivery.

[Generic host adapter contract](10-generic-host-adapter.md) owns the exact
delivery-fence operation and adapter scheduling surface.

The core registry stores this existential package:

```ocaml
type packed =
  | Pack : {
      codec : 'payload Exported_endpoint.Codec.t;
      endpoint : 'payload Endpoint.t;
      gate : export_gate;
      permits : dispatch_permits;
    } -> packed
```

The package proves that decoder output matches endpoint input. Dispatch requires
no `Obj`, public type witness, or untyped action closure.

### Serialized dispatch

The core-facing session surface is:

```ocaml
module Serialized_session : sig
  type t

  type request_error =
    | Malformed_handle
    | Unknown_handle
    | Stale_handle
    | Revoked_handle
    | Malformed_payload

  type session_error = Session_closed

  val try_invoke :
    t ->
    handle:bytes ->
    payload:bytes ->
    ((Exported_endpoint.try_result, request_error) result, session_error) result
end
```

Transport errors wrap this result outside Eta Crux core. They never become
handle, capacity, or endpoint-admission errors.

Dispatch uses this order:

1. Acquire the root lock and reject a closed session.
2. Parse and authenticate the bounded handle while holding the root lock.
3. Validate the export and create a permit that pins its codec and binding.
4. Release the root lock, then decode and map under the callback guard.
5. Acquire the root lock and check root ingress.
6. Enqueue while acquiring the queue lock after the root lock.
7. Release the dispatch permit on every return or exception path.

The open-session check is the session-closure linearization point. A valid
export receives its permit in the same root-lock critical section.

Handle size has a fixed protocol bound. Handle parsing and authentication run no
application callback.

Session closure, rebinding, and revocation wait when permit acquisition wins.

If closure or structural commit wins, permit acquisition returns its error. No
decoder or mapper runs.

A commit that changes the pinned export waits without holding the root lock. A
commit that does not change that export does not wait for its permit.

No operation acquires the root lock after the queue lock. This lock order applies
to invocation, ingress shutdown, and advancement polling.

Invalid handle syntax returns `Malformed_handle`. Authentication failure returns
`Unknown_handle` and reveals no authentication detail.

An authenticated older session or generation returns `Stale_handle`. The
current tombstoned generation returns `Revoked_handle`.

An authenticated future generation or unissued slot returns `Unknown_handle`.
A decoder error returns `Malformed_payload` without its local diagnostic text.

Closed ingress wins over `Full` after successful handle and payload processing.
Every rejected result enqueues nothing.

Session closure and invocation use first-winner arbitration. An invocation starts
when it acquires its permit and then finishes its synchronous dispatch.

A closure that wins returns `Session_closed` and performs no handle or codec
work. It enqueues nothing.

### Callback defects

A decoder that returns `Error` produces `Malformed_payload`. A decoder that
raises produces a defect.

A mapper inside `Endpoint.contramap` runs under a callback guard without the root
lock. A mapper exception is a defect.

Synchronous callback re-entry into Eta Crux fails immediately as a defect. The
guard prevents callbacks from waiting on their own dispatch permit.

Eta Crux atomically latches either defect as a root crash and closes ingress. It
then re-raises the same exception to the synchronous caller.

The invocation releases its permit before it returns or re-raises.

The failure origin is `Export_dispatch`. The trigger is
`Local_export_invocation` or `Serialized_export_invocation`.

The fatal latch arbitrates with structural commit through the existing root
failure rules. A decoder or mapper exception never becomes malformed payload,
capacity failure, or endpoint-admission failure.

### Advancement lane selection

`Root.advance` first checks the fatal latch. A latched failure produces the crash
outcome before queue selection.

Otherwise, advancement takes the oldest control event. It polls the oldest
application action only when the control lane is empty.

This priority does not change FIFO order within either lane. Stop and startup
cannot wait behind a full application queue.

### Prototype evidence

The selected prototype is on branch `prototype/eta-crux-exported-endpoint` at
commit `fea8c9ea`:

- [prototype](https://github.com/ribelo/eta/tree/fea8c9ea/.scratch/prototypes/eta-crux-exported-endpoint)
- [design](https://github.com/ribelo/eta/blob/fea8c9ea/.scratch/prototypes/eta-crux-exported-endpoint/DESIGN.md)
- [public surface](https://github.com/ribelo/eta/blob/fea8c9ea/.scratch/prototypes/eta-crux-exported-endpoint/public_surface.mli)
- [queue addition](https://github.com/ribelo/eta/blob/fea8c9ea/.scratch/prototypes/eta-crux-exported-endpoint/eta_queue_addition.mli)
- [results](https://github.com/ribelo/eta/blob/fea8c9ea/.scratch/prototypes/eta-crux-exported-endpoint/RESULTS.md)

The prototype covers local and serialized invocation, recomputation, revocation,
re-entry, slot reuse, malformed requests, capacity, closure, session replacement,
dispatch permits, callback re-entry, callback defects, replacement crash, and
lane selection.

It compiles under OxCaml and upstream OCaml 5.4.1. The local and serialized paths
enqueue the same typed action in the equivalence scenario.

### Rejected alternatives

Eta Crux does not derive export identity from output snapshots or target
endpoints. Both schemes fail for recomputation or distinct narrowed exports.

Adapters do not own export activation, revocation, or application-supplied export
keys. Local transport does not use serialized machinery.

Eta Crux does not export complete action protocols, change codecs behind stable
handles, retain every historical token, or use one catch-all invocation error.

It does not add a private concurrency queue. Eta owns the synchronous queue
primitive and its cross-domain admission rules.
