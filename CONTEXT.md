# Eta domain glossary

## Signal behavior contract

The externally observable rules for Signal values, failures, ordering,
lifecycle, cancellation, and stabilization. Internal execution structures are
not part of this contract.

## Affected work

The Signal nodes, edges, keys, and lifecycle records that one admitted change
can alter. An operation is change-proportional when its work follows this set.

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

## Endpoint

A typed local capability for enqueueing actions to one live state-machine
incarnation.

## Source

A structurally owned producer whose items and terminal outcome become actions.
Its specification defines producer continuity.

## Root output

The complete application value that current Eta Crux V1 publishes from one
successful commit. The typed projection target keeps the root result local.

## Latest committed output

The current Eta Crux V1 Root output from the greatest completed commit. The
typed projection target replaces this term with the latest committed projection
state.

## Latest delivered output

The current Eta Crux V1 Root output whose delivery token the host last accepted.
The typed projection target replaces this term with the latest delivered
projection state.

## Projection

A structural computation occurrence that produces one typed, complete derived
value.

## Projection value

The complete typed value that one projection produces for one committed graph
state.

## Projection kind

One generative immutable descriptor for keyed projection values.

## Projection catalog

The closed ordered set of projection kinds in one root contract.

## Projection identity

One projection kind and one equivalent key. The identity can have several
projection incarnations over time.

## Projection incarnation

One continuous active lifetime of one projection identity.

## Projection attachment

The association between an active projection incarnation and its current
projection value.

## Projection update

One `Attached`, `Changed`, or `Removed` member of a projection batch. `Attached`
starts an incarnation and carries its first projection value. `Changed` carries
a changed projection value. `Removed` records a projection removal.

## Projection batch

One atomic ordered sequence of projection updates from one successful commit. A
projection batch can be empty.

## Projection image

The complete framework-owned outward state from one successful commit. It
contains all active projection attachments.

## Projection state

The state of one projection identity. It is either `Active` with an incarnation
and projection value, or `Absent`.

## Latest committed projection state

The projection state after the latest completed commit.

## Latest delivered projection state

The projection state after the latest projection delivery that the host
accepted.

## Changed projection value

The complete new value carried by a `Changed` projection update. It is not a
diff.

## Projection removal

A `Removed` projection update that ends the active incarnation and makes the
projection state `Absent`.

## Projection bootstrap

The process that gives a serialized shell session its starting projection
states.

## Bootstrap snapshot

An atomic snapshot that carries the starting projection states for a projection
bootstrap.

## Ingress item

One value accepted by the root ingress queue. Actions, reset triggers, Poll
refreshes, and Poll completions are ingress-item classes.

## Ingress queue

The bounded root queue that accepts ingress items. Internal control events do
not use this queue.

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

## Driver attachment

The exclusive connection between one unstarted root and its production driver.
The attachment gives that driver sole authority to advance the root.

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

One atomic attempt to process one selected ingress item or internal control
event and produce a committed application output.

## Post-commit batch

Opaque work that belongs to one committed advancement. Starting it acknowledges
output delivery and admits the owned work from that advancement.

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

## Structural reset

One atomic graph-owned model transition for every active state-machine
descendant of an explicit reset scope. Normal reconciliation applies after the
model changes.

## Graph time

Eta Crux monotonic time that can change graph output through a driver
advancement. Eta Crux owns its computations, deadline schedule, and driver
wakes.

Graph time does not use `Eta_signal.Time`. Eta supplies the monotonic clock and
sleep operation.

## Poll run

One effect execution that a Poll starts after activation, a significant input
change, or manual refresh. A Poll run does not use the shell request protocol.
Poll terminology is run, run order, and run history — never request.

## Poll

A graph-owned computation that starts Poll runs when it activates, its input
changes significantly, or a caller runs a manual refresh. The input cutoff
defines a significant change.

Each active interval has one hidden run order. The result with the greatest
committed run order is current. A new run does not cancel an earlier run in the
same active interval.

Disposal requests cancellation and fences later completions. A later
incarnation starts with a fresh run order and starting state.

## Ownership

Eta owns effect execution, scheduling, interruption, scopes, finalizers,
clocks, and sleeps. Eta Crux owns graph time, active deadlines, clock
sampling, driver wakes, actions, ingress, structural reset, Poll run order,
commit publication, shell requests, handler claims, and request settlement.
`Driver` owns the latest committed `Projection.Snapshot.t` in the typed
projection target. Adapters own
successful-delivery state, host reconciliation, registration, operation
routing, buffers, retries, and provider diagnostics. `Eta_crux.Testing` owns
the post-commit observation types and observer attachment. `eta_crux_test`
owns the observer controller and destructive reads. Applications own models,
builders, Poll inputs, cutoffs, result values, and domain policy.
