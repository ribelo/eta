# Long-lived sources and subscriptions

Type: grilling
Status: resolved
Blocked by: 05, 07

## Question

Does Eta Crux need a first-class subscription concept, or do scoped Eta effects
and streams already express every required long-lived source?

Compare at least:

- one lifecycle program that runs a scoped stream-consumer effect.
- Elm-style desired subscriptions derived from committed computation state.
- keyed source declarations reconciled by identity.
- host-owned sources that start and stop through an adapter protocol.

Decide identity, update, restart, failure, item injection, cancellation, and
shutdown semantics. Include the race where a transition both declares a source
and stages the effect that can emit its first item. Avoid a framework concept if
Eta `Resource`, `Stream`, and scoped effects already supply the same invariant.

## Answer

### Public concept

Eta Crux exposes a thin `Source` computation. V1 does not expose an Elm-style
`Subscription.t` algebra. Ordinary computation composition combines sources,
and `Assoc` expresses keyed source collections.

A source uses one generic, two-phase Eta producer. The semantic producer type
is:

```ocaml
type 'item emitter = {
  emit :
    'item ->
    (unit, Endpoint.admission_error) Eta.Effect.t;
}

type ('item, 'error) producer =
  'item emitter ->
  ((unit, 'error) Eta.Effect.t, 'error) Eta.Effect.t
```

Eta Crux supplies the emitter. Its admission error remains separate from the
producer error channel. This form keeps item emission composable and makes root
closure explicit to the producer or host adapter.

The outer effect opens the source and installs its item-admission path. Success
returns the long-lived producer effect. Eta Crux then runs that effect in the
source owner scope.

This type is a semantic sketch. [OCaml API syntax and ergonomics](14-ocaml-api-ergonomics.md)
owns final names and argument order.

### Identity and updates

The description node locates the source declaration. A changing spec value and
one graph-neutral `Cutoff.t` define source continuity.

A candidate spec that the cutoff suppresses preserves the producer. Eta Crux
updates item and terminal mappers at the atomic graph commit. Later events use
the latest committed mappers without a producer restart.

The mapper closures and producer factory do not participate in identity. The
spec contains every value that changes producer registration or execution. A
later active interval samples the latest producer factory and spec.

A candidate spec that the cutoff accepts creates a fresh source incarnation. The post-commit batch first
requests cancellation of the old incarnation. The replacement can start while
old finalizers run.

### Opening and readiness

Successful outer-effect completion is the source readiness signal. Readiness
means that the item-admission path is live. It does not include unrelated remote
protocol progress.

The outer effect returns after it installs the admission path. Unbounded source
work belongs in the returned producer effect.

All new source openings start concurrently after cancellation requests return.
The same post-commit batch keeps its transition effect gated until every opening
reports readiness or a typed opening failure.

A typed opening failure maps to a terminal action and resolves its opening
barrier. Eta Crux enqueues that action before it releases the transition effect.
The source remains structurally active and terminal.

Work that requires successful opening belongs at the start of the returned
producer effect. Independent work remains in the transition effect.

### Item and terminal delivery

For each item, Eta Crux reads the latest committed item mapper. It maps the item
to an action and sends that action through the declared target `Endpoint.t`.

Each send appends one normal endpoint message. A message that arrives during an
advancement waits for a later advancement. Sources do not mutate models or the
graph directly.

An emitter returns `Ingress_closed` if root closure wins its admission race. The
producer or host adapter handles that result. Eta Crux does not reinterpret it as
a source failure or terminal action.

Terminal-action delivery uses the same admission rule. If closure wins, Eta Crux
queues no terminal action because the root already owns terminal progress.

The semantic terminal value is:

```ocaml
type 'error terminal = [ `Completed | `Failed of 'error ]
```

Normal producer completion maps `Completed` to an action. A typed producer
failure maps `Failed error` to an action. Both paths use the latest committed
terminal mapper.

The source remains structurally active and terminal after either outcome. Eta
Crux does not retry or restart it. The application changes the spec or creates a
fresh dynamic child to start another incarnation.

Defects cross the crash boundary. [Failure, defect, and crash boundary](11-failure-boundary.md)
defines the root result and driver report.

### Cancellation and shutdown

Committed source removal makes the source incarnation stale immediately. The
post-commit batch requests producer cancellation and leaves cleanup under Eta
supervision.

Disposal interruption produces no terminal action. Messages from the old
incarnation retain its token and receive `Stale_endpoint` during delivery.

Root shutdown closes ingress and interrupts every source through the root
ownership tree. The final post-commit batch waits for all source work and
finalizers before the root enters `Closed`.

### Adapters and package boundary

Eta streams enter through a small producer adapter. Host callback systems use
the same producer contract and report readiness after event registration.

The generic producer keeps `eta_stream` and host libraries out of the Eta Crux
core dependency set. [Package and module boundaries](15-package-boundaries.md)
owns final package names and dependency placement.

Host adapters provide producer values. They do not own source identity,
reconciliation, cancellation, or restart policy.

### Rejected alternatives

Eta Crux does not use lifecycle programs as the only public source recipe. That
recipe lacks an explicit spec cutoff and readiness semantics.

Eta Crux does not add `Subscription.empty`, `Subscription.batch`, or a second
composition language. Computation structure already supplies composition and
lifetime ownership.

Eta Crux does not move canonical source ownership into host adapters. It also
does not infer identity from mapper closures, restart on mapper changes, hide
automatic retries, or emit terminal actions for disposal interruption.
