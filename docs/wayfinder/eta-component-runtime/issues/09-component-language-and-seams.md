# Component language and seams

Type: grilling
Status: resolved
Blocked by: 03, 08

## Question

What canonical terms and module seams describe Eta components, component
instances, contexts, coeffects, providers, committed dependency views, and
desired state?

Keep `Component` and `component instance` as the approved declaration and
installation terms. Decide whether `Coeffect` is a public Eta term or only the
formal name for a dependency contract. Avoid collisions with Eta Runtime,
capabilities, services, scopes, and fibers.

Record the resolved domain terms in `CONTEXT.md`. Define the external seams
without selecting their final OCaml signatures.

## Answer

### Canonical language

`Coeffect` is a public Eta term. It names a typed dependency contract. The
contract defines typed key identity, observable operations, and value
equivalence. A provision supplies an ordinary typed OCaml value for a coeffect.
It does not supply a universal provider handle.

`Requirement` and `Provision` describe declarations. A requirement declares
that a component needs a coeffect. A provision declares that a component
supplies a coeffect.

`Consumer` and `Provider` describe runtime roles for one coeffect. They are not
fixed component kinds. One component can consume one coeffect and provide
another.

A `Provider episode` is one activation generation of one component instance.
Provider identity includes the component instance and the activation
generation.

A `Component` is a reusable declaration. A `Component instance` is one live
installation of that declaration. The component runtime constructs an instance
from a component declaration and a desired-state entry.

A `Component context` is the long-lived lifecycle authority. It owns provider
availability, component instances, registrations, reconciliation, and shutdown.
The term does not name an effect environment, an Eta runtime, or an
activation-local object.

A `Committed provider view` maps each requirement of one consumer activation to
one provider episode. It is a semantic and diagnostic concept. The runtime
controls the view. Activation code receives only its declared typed values.

`Desired state` is the immutable lifecycle authority supplied by the
application. A `desired-state tree` contains entries. An entry identifies
requested structure and can carry a component declaration and application-owned
configuration.

`Reconciliation` interprets desired state and moves the component context toward
the requested committed state. Configuration remains application-owned data. It
is not a second lifecycle authority.

Applications can observe desired-state entry identities and immutable lifecycle
or provider observations. Mutable component-instance and provider handles do
not escape.

### External seams

The design has four external conceptual seams. Later prototypes select their
OCaml signatures and final module layout.

#### Coeffect definition

This seam defines typed key identity, observable operations, and value
equivalence. It does not expose a mutable provider registry or component
lifecycle operations.

#### Component authoring

This seam defines reusable component declarations, requirements, provisions,
and activation work. The runtime supplies declared typed values and a narrow
interface for tracked work. A successful activation stages exactly its declared
provisions.

The activation interface does not expose the complete component context. A
component does not implement public `start` and `stop` operations or own its
recovery protocol.

#### Desired-state construction

This seam constructs an immutable desired-state tree. It performs no loading,
effect execution, or reconciliation.

Loader adapters convert serialized or module-derived input into desired state.
They remain outside the component-runtime core.

#### Component-context control

This seam creates and owns the long-lived component context. An application
submits desired state, requests reconciliation, waits for settlement, and shuts
down the context.

The context owns component-instance construction, provider publication,
committed provider views, lifecycle coordination, and reconciliation order. An
application cannot mutate an instance or provider directly.

An explicit retry is a context-level reconciliation request. The runtime
reevaluates the current desired state. The request does not expose a mutable
component-instance handle.

### Adapter seams and rejected collisions

A loader adapter produces desired state. A runtime adapter supplies the Eta
execution substrate. Later tickets define these adapter interfaces and package
ownership.

Eta `Runtime` remains the effect interpreter. Eta scopes remain lexical resource
owners. Eta fibers remain concurrent computations. Eta capabilities remain
runtime traits. Application services remain ordinary values.

The component runtime does not add an environment channel to `Effect.t`. It
does not use runtime services, runtime locals, or the component context as
ambient dependency lookup.

This decision does not select key representation, lifecycle states, desired
state structure, reconciliation algorithms, final signatures, or public package
names. Those choices remain in their named tickets.
