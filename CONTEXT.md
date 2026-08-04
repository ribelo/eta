# Eta domain glossary

## Eta Crux

An Eta-native framework for incremental, composable state machines. It is
generic application-computation infrastructure, not a UI or GUI framework.

## Diffable map

An immutable ordered map that can compare two snapshots and report key
additions, removals, and data changes.

## Map snapshot

One immutable value of a diffable map at a point in an application workflow.

## Shared persistent ancestry

A relationship between snapshots derived from a common snapshot through
immutable edits. Unchanged tree regions retain physical identity.

## Diff frontier

The changed entries and unshared tree paths that a map comparison must inspect.

## Change-proportional reconciliation

Reconciliation whose work follows the diff frontier instead of the total map
size. This term applies only to snapshots with shared persistent ancestry.

## Keyed child incarnation

One continuous lifetime of a keyed child. Removal ends the incarnation, and a
later entry of the same key starts a new incarnation.

## Action

A typed input addressed to one live cell and consumed by that cell's
transition.

## Message

A boundary envelope or shell-capability value. A cell input is an action, not a
message.

## Model

The application value owned by one cell. State is the general term for runtime
state or aggregate application state.

## Scheduled command

Deferred command work together with its ownership, ordering, and replacement
metadata.

## Command work

A force-total Eta effect that resolves to one action.

## Subscription

A state-derived long-lived source whose items become actions.

## Fragment

One typed application output exposed at an address.

## Output tree

The aggregate of all live fragments in an application instance.

## Startup input

The reserved name for host-supplied startup data. Its type and lifecycle are not
part of this glossary.

## Endpoint

A typed local capability for enqueueing actions to one live state-machine
incarnation.

## Ingress queue

The bounded root queue that accepts application actions from internal endpoints
and exported endpoints. Internal control events do not use this queue.

## Exported endpoint

An endpoint deliberately exposed to a shell with a payload serialization
contract.

## Export node

A structural computation occurrence that gives an exported endpoint its own
identity and active interval.

## Remote handle

An opaque authenticated transport token that represents an exported endpoint
during one serialized shell session.

## Serialized shell session

An explicit lifetime that binds one serialized driver to one shell and scopes
all remote handles for that binding. One driver has at most one active session.

## Shell

The imperative, host-specific side that presents output, performs external
work, and returns actions to the application core.

## Host runtime

The external execution environment or event loop that hosts a shell. Its
startup and shutdown can occur outside OCaml and outside Eta Crux.

## Adapter binding

One live connection between an Eta Crux root and a host runtime. It owns the
private reconciliation state and host event registrations for that root.

## Transport

The means by which the application core and shell exchange information. A
transport does not change application semantics.

Local request transport carries typed values directly. Serialized request
transport adds codecs, authenticated identities, and protocol errors.

## Request

A framework-owned one-shot exchange across the shell boundary. Eta Crux gives
each request opaque identity and accepts one resolution. The structural scope
that starts or receives the request owns it.

## Pending request

A request that has no accepted resolution and whose owning scope remains active.
It remains pending until resolution, initiator cancellation, owner disposal, or
root termination. Eta Crux adds no default timeout.

## Request capacity

The root-wide bound on all pending inbound and outbound requests. Outbound Eta
effects can wait for capacity. Nonblocking inbound admission reports `Full`.
`Root.create` requires a separate positive request capacity. There is no default
or unbounded mode.

## Request resolution

The first accepted typed response for a request. Expected operation failure is
part of the application-defined response value, not the framework lifecycle.
A later resolution attempt returns `Not_pending`.

## Request cancellation

A terminal request outcome caused by initiator cancellation, owner disposal, or
root termination. Eta Crux closes the request identity before it sends a
cancellation notice. The notice requires no peer acknowledgment.

A waiting peer observes one reason: `Initiator_cancelled`, `Owner_disposed`,
`Root_stopped`, `Root_crashed`, or `Session_closed`. The reason contains no Eta
cause or structural data.

A serialized-session replacement does not replay requests from the old session.

## Outbound request

A request that the application core starts and the shell resolves.

## Requester

An explicit typed value that grants authority to start one kind of outbound
request. Application or adapter modules can wrap a requester as a domain
operation.

The integration constructs transport-bound requesters and passes them to the
application builder as ordinary typed dependencies.

A requester effect requires Eta Crux-owned work with a structural owner. Use in
another execution context is invalid.

## Host operation

One named kind of shell-owned work with typed request and response contracts.
An integration binds a host operation to a requester. Application computations
receive the requester, not its transport metadata.

## Request event

A driver event that asks the shell to dispatch one outbound request. It carries
an opaque token for dispatch acknowledgment and later resolution.

Dispatch acknowledgment means that the peer accepted the request and installed
its response and cancellation paths. It does not mean that the operation is
complete.

Cancellation and dispatch acceptance use first-winner arbitration. A canceled
unaccepted request does not start. An accepted request receives a cancellation
notice.

## Operational telemetry

A fixed payload-free set of logs, metrics, and spans that Eta Crux emits through
Eta observability effects. Operational telemetry exposes semantic operation
categories and outcomes. It does not expose application values or graph
identity.

## Inbound request

A request that the shell starts and the application core resolves.

## Request export

A structural computation occurrence that accepts one kind of inbound request.
It maps each admitted request and its responder to an ordinary action.

The export wraps an endpoint for the request and responder pair. Serialized
transport adds separate request and response codecs.

## Responder

An opaque value that grants authority to resolve one inbound request. The
application can retain it for later work in the owning structural scope.

Successful resolution means that Eta Crux accepted the first response and
queued its handoff. It does not mean that the peer consumed the response.

## Advancement

One atomic attempt to process a single queued action and produce a committed
application output.

## Post-commit batch

Opaque work that belongs to one committed advancement. Starting it acknowledges
output delivery and admits lifecycle and transition effects.

## Test handle

A test-owned shell connection that drives one root through the production driver
protocol. The handle has exclusive protocol ownership during its lifetime.

## Test frame

One test operation that performs at most one root advancement through output
delivery and complete post-commit admission.

## Active child

A child computation that is present in the current application structure.

## Active interval

One continuous period during which a child remains present in the application
structure.

## Disposed child

A former child whose active interval ended. A later appearance creates a new
child incarnation.
