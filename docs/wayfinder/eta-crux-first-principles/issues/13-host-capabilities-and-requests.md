# Host capabilities and request-response

Type: grilling
Status: resolved
Blocked by: 05, 07, 08, 10, 11

## Question

What typed request-response contract lets returned Eta effects ask the shell to
perform host-owned work through either local or serialized transport?

Test the decision against an HTTP handler, an LSP request, a tool call, process
execution, a file picker, and one long-lived host source. Decide:

- whether request identity and exactly-once resolution are framework concepts.
- whether inbound host asks are supported as well as outbound requests.
- cancellation when the owning dynamic scope disappears.
- late, duplicate, missing, and streaming responses.
- whether in-process typed calls differ from cross-process serialized calls.
- which failures belong to Eta Crux, the application protocol, or the adapter.
- how `Ingress_closed` affects request admission and pending resolution.
- how root crash settlement closes unresolved host requests.

One-shot resolution is separate from repeated state-machine endpoints. Do not
copy Rust Crux request machinery merely because it exists.

Long-lived repeated host events use the generic producer from [Long-lived
sources and subscriptions](08-subscriptions-and-sources.md). This ticket owns
one-shot request resolution and does not add another streaming response path.

[Failure, defect, and crash boundary](11-failure-boundary.md) keeps admission
closure separate from interruption and root crash. The request protocol must
preserve those distinctions.

## Answer

### Boundary

Eta Crux owns one request concept with two direction-specific APIs. An outbound
request starts in the application core and resolves in the shell. An inbound
request starts in the shell and resolves in the application core.

Each request has opaque framework identity and accepts one typed response. The
first resolution wins. A later resolution returns `Not_pending`. An invalid
serialized identity is a protocol error instead of a resolution error.

Expected operation failures remain application-defined response values. For
example, a tool operation can respond with `(tool_result, tool_error) result`.
Eta Crux errors describe admission, dispatch, and lifecycle only.

The framework provides no streaming or `Many` request form. Repeated host events
use the `Source` contract from [Long-lived sources and subscriptions](08-subscriptions-and-sources.md).

### Public semantic surface

The shared framework values have this semantic shape:

```ocaml
module Request : sig
  type closure_reason =
    | Initiator_cancelled
    | Owner_disposed
    | Root_stopped
    | Root_crashed
    | Session_closed

  type not_pending = Not_pending

  module Driver_event : sig
    type t
  end
end

module Requester : sig
  type ('request, 'response) t

  type error =
    | Ingress_closed
    | Dispatch_failed
    | Closed of Request.closure_reason

  val request :
    ('request, 'response) t ->
    'request ->
    ('response, error) Eta.Effect.t
end

module Responder : sig
  type 'response t
  type error = Request.not_pending

  val resolve :
    'response t ->
    'response ->
    (unit, error) Eta.Effect.t
end

module Request_export : sig
  type ('request, 'response) t
  type availability_error = Stale | Revoked

  type invoke_error =
    | Unavailable of availability_error
    | Request_capacity_full
    | Ingress_capacity_full
    | Ingress_closed
    | Closed of Request.closure_reason

  val invoke :
    ('request, 'response) t ->
    'request ->
    ('response, invoke_error) Eta.Effect.t
end
```

These operation-specific errors are not one catch-all request taxonomy. Export
availability, request capacity, ingress capacity, ingress closure, serialized
protocol errors, and adapter failures remain distinct layers.

An integration constructs transport-bound `Requester.t` values. It passes them
to the application builder as ordinary typed dependencies. Application or
adapter modules can wrap one requester as a domain operation. Eta Crux defines
no concrete dialog, file, clipboard, window, HTTP, LSP, or tool API. It also
defines no ambient requester registry.

`Requester.request` is valid only inside Eta Crux-owned work with a structural
owner. Use in another execution context fails as an invalid-request-scope
defect. It never silently assigns root ownership.

`Request_export.invoke_error` keeps export availability and both capacity limits
distinct. Serialized session and protocol errors wrap this local result at the
transport boundary.

### Outbound requests

Interpreting `Requester.request requester request` waits for root request
capacity. Admission then creates one request identity, binds it to the current
structural owner, and emits one driver request event.

The adapter acknowledges dispatch only after the peer accepts the request and
installs response and cancellation paths. Acknowledgment does not mean that the
host operation is complete.

A reported inability to dispatch resolves the requester effect with
`Dispatch_failed`. An accepted response resolves it with the application-defined
response value. Owner interruption uses Eta interruption and requests framework
cancellation.

Eta `Effect.async` supplies the one-shot wait and cancellation race. Eta Crux
does not add a promise or callback runtime primitive.

### Inbound requests

`Request_export` is a dedicated structural computation node. It wraps an
endpoint whose payload is a typed request and opaque `Responder.t`. Admission
maps that pair to one ordinary action. It never invokes a state-machine callback
outside advancement.

The request export inherits the active-interval, generation, revocation,
re-entry, and dispatch-permit laws of `Exported_endpoint`. It has a separate
request protocol and separate request and response codecs for serialized use.
Local use performs no codec or handle work.

The effect performs nonblocking admission, waits for one response, and cancels
the request if the waiting fiber is interrupted. Adapter internals use a lower
token surface for serialized and foreign-loop initiation. That surface has an
explicit cancellation operation.

Only post-commit Eta effects can call `Responder.resolve`. Application code can
retain a responder for later owner-scoped work. A failed advancement publishes
neither its model nor a response. Successful resolution means that Eta Crux
accepted the first response and queued its handoff. It does not mean that the
foreign peer consumed the response.

If the queued inbound action becomes stale before advancement, Eta Crux rejects
the action and closes the request with `Owner_disposed`. The request never waits
for application cleanup that cannot run.

### Lifetime and capacity

The structural scope that starts or receives a request owns it. A request
remains pending until resolution, initiator cancellation, owner disposal, root
termination, or serialized-session closure. Eta Crux adds no default timeout.
Applications express operation-specific deadlines with Eta effects.

Cancellation closes the request identity before it sends a peer notice. It does
not wait for peer acknowledgment. Cancellation and dispatch acceptance use
atomic first-winner arbitration:

- Cancellation before acceptance suppresses the request event and starts no
  host work.
- Acceptance before cancellation emits a cancellation notice to the peer.
- Resolution before cancellation returns the response.
- Cancellation before resolution makes the later resolution return
  `Not_pending`.

`Root.create` requires a positive `request_capacity` that is separate from
`ingress_capacity`. There is no default or unbounded request mode. One root-wide
capacity bounds inbound and outbound requests.

Outbound Eta effects wait for request capacity. Nonblocking inbound admission
reports request `Full` separately from ingress `Full`. A slot remains occupied
until dispatch failure settles or the adapter accepts the terminal response or
cancellation handoff. The root never waits for foreign consumption or
cancellation acknowledgment.

### Driver and adapter protocol

Outbound dispatch, response handoff, and cancellation handoff are request
driver events. The active output-delivery and post-commit fence remains first.
After that fence, terminal request handoffs precede FIFO outbound dispatch
events. Both precede the next application advancement. Stop and crash retain
their existing control priority.

An adapter event answer is one-shot. For outbound dispatch, the adapter reports
accepted or failed. Acceptance installs the later response and cancellation
paths. Response and cancellation events complete when the adapter accepts their
handoff, not when the peer consumes them.

Root settlement closes every local request and waits for adapter acceptance of
all required terminal handoffs. It does not wait for a peer acknowledgment. If
an active adapter cannot accept an admitted response or required cancellation
notice, Eta Crux records a fatal failure with origin `Request_dispatch`. During
an existing crash, this record becomes secondary evidence.

### Ingress, stop, and crash

`Ingress_closed` rejects new inbound and outbound requests. It does not reject a
resolution for a request that is already pending. Resolution and cancellation
continue to use first-winner arbitration.

The root crash latch closes ingress but does not immediately cancel pending
requests. Existing resolutions remain eligible through crash notification. The
terminal batch then atomically cancels unresolved requests, emits the required
notices, interrupts owned work, and settles local handoffs.

Normal stop uses the same request fence with `Root_stopped`. Crash uses
`Root_crashed`. The peer receives only the closure reason. It receives no Eta
cause, cell identity, graph path, or structural data.

### Transport

Local and serialized transports preserve one request contract. Local transport
uses typed request and response values directly. It allocates no remote handle
and performs no encoding.

Serialized transport adds request and response codecs, authenticated
session-scoped identities, bounded generational slots, and protocol errors.
Session loss closes requests bound to that session with `Session_closed` but
does not crash the root. A replacement session never replays an old request.

A terminal serialized slot can report `Not_pending` until slot reuse. Reuse
increments its generation, so an older identity becomes a stale protocol value.
This rule bounds registry storage by peak request use instead of total request
history. [Wire codec and protocol contract](17-wire-codec-protocol.md) owns the
frame grammar and exact protocol errors.

### Scenario checks

An HTTP handler, LSP request, or tool call enters through a request export. The
action can change state and stage response work. A process execution request can
return its one terminal result, while repeated output uses `Source`.

A file picker is one possible host operation, not a framework concept. Its
requester can return a typed selection result. The same request machinery has no
UI or GUI assumption.

A missing response remains pending until a defined terminal event. Duplicate and
late responses return `Not_pending`. Session replacement never retries or
replays external work.

### Rejected alternatives

Eta Crux does not require application correlation tokens, a global operation
GADT, or an ambient capability registry. It defines no concrete host APIs or
synchronous callback mutation.

It does not add streaming request handles, default timeouts, or unbounded
request state. It does not serialize local values or replay work after session
replacement.

It does not wait for foreign cancellation acknowledgment. It never silently
discards late responses or converts transport failures into application response
values.
