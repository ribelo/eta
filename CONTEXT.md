# Eta domain glossary

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

## Advancement

One atomic attempt to process a single queued action and produce a committed
application output.

## Post-commit batch

Opaque work that belongs to one committed advancement. Starting it acknowledges
output delivery and admits lifecycle and transition effects.

## Active child

A child computation that is present in the current application structure.

## Active interval

One continuous period during which a child remains present in the application
structure.

## Disposed child

A former child whose active interval ended. A later appearance creates a new
child incarnation.
