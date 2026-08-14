# Component lifecycle and failure

Type: prototype
Status: resolved
Blocked by: 08, 11

## Question

Which component-instance state machine preserves Eta failure, cancellation, and
cleanup semantics during activation, deactivation, reactivation, and partial
failure?

Prototype inertial transitions and target changes during asynchronous work.
Decide where typed activation errors live, whether sibling instances continue,
when retries are legal, and how a failed instance returns to service.

The answer must preserve complete Eta causes and must not leak an escaping fiber
handle as the ownership model.

## Answer

Use one serialized, inertial state machine for each component instance. Keep
the latest desired target separate from the current lifecycle phase.

### Lifecycle phases

The internal machine has six semantic phases:

- `Inactive` has no live or staged generation.
- `Activating` runs one fresh generation and stages its provisions.
- `Active` owns one committed provider episode.
- `Settling` has closed admission and waits for owned work and cleanup.
- `Activation_failed` retains a settled activation cause.
- `Recovery_failed` retains a failed-cleanup cause and quarantines the
  instance.

One private coordinator serializes events for each instance. A backend adapter
runs the Eta effects. No fiber or supervisor handle escapes this ownership
seam.

The desired target records the declaration, configuration, provider view, and
retry authority selected by reconciliation. The later reconciliation design
can refine its representation. It must preserve target identity across
asynchronous transitions.

Each activation gets a fresh, monotonically increasing generation. A
successful commit turns that generation into a provider episode. A later
activation never reuses the generation or its Eta scope.

### Inertial transitions

A target change closes generation admission before it requests cancellation.
Work already admitted can land, register its recovery witness, and settle.

If the target changes during `Activating`, that generation cannot commit. Its
activation result and Eta scope must settle before the next generation starts.

If the target changes during `Active`, the instance enters `Settling`.
Dependency-safe withdrawal decides when its activation scope can close. That
ordering belongs to [Reactive resolution and withdrawal](13-reactive-resolution-and-withdrawal.md).

If another target arrives during `Settling`, it replaces the pending target.
It does not reverse settlement or start overlapping work. After clean
settlement, the coordinator starts only the latest target.

A target that becomes unavailable and later returns with a new provider episode
remains a changed target. Equal provider values do not permit the stale
generation to commit.

### Activation outcomes and causes

An activation succeeds only when its result commits against the current target.
The runtime publishes its complete declared provisions at that commit point.

An activation `Exit.Error cause` becomes the primary activation cause. The
instance closes admission and settles every tracked effect before it exposes a
terminal failure.

Requested interruption-only cancellation is a lifecycle control result. It
does not create an activation failure. An unexpected interruption remains part
of the activation cause.

If activation cleanup succeeds, the instance enters `Activation_failed` with
the original cause. It has no committed provider view and publishes no staged
provisions.

If cleanup fails, Eta retains its ordinary complete cause structure. A primary
activation failure and cleanup failure remain a `Cause.Suppressed` result.
Cleanup failure after a successful primary result remains a `Cause.Finalizer`
result.

The runtime stores the typed cause in a private existential generation outcome.
The conceptual shape is:

```ocaml
type failure =
  | Failure : {
      generation : int;
      cause : 'error Cause.t;
    } -> failure
```

The public diagnostics design can add safe rendering and observation. It must
not flatten this value into an OCaml `result`, string, or log-only event.

### Failure locality and context health

Activation failure is local to one component instance. Unrelated siblings
continue, and the component context continues lifecycle coordination.
Dependent behavior follows provider availability and belongs to
[Reactive resolution and withdrawal](13-reactive-resolution-and-withdrawal.md).

Recovery failure does not prove observational recovery. The instance enters
`Recovery_failed`, rejects new generations, and remains quarantined.

One quarantined instance marks its component context as degraded. The context
continues to coordinate unrelated instances, settlement, diagnostics, and
controlled shutdown. It does not report healthy settlement.

A recovery failure does not stop the complete context by default. Stopping an
independent sibling cannot repair the failed recovery witness and can cause a
larger cleanup cascade.

A component-runtime invariant violation is different from a component recovery
failure. A coordinator defect or impossible state stops the complete component
context and preserves its cause.

### Retry and return to service

`Activation_failed` can return to service in two cases:

- Reconciliation selects a different target.
- An explicit context-level retry request selects a fresh retry generation.

Unchanged desired state does not retry automatically. Each retry uses a fresh
generation, activation scope, and provider-episode identity.

`Recovery_failed` cannot retry in the same component context. A target change
can update desired state, but it cannot start another generation. Return to
service requires external remediation and a fresh ownership boundary.

A recovery operation that does not terminate leaves the instance in
`Settling`. The settlement fence remains pending. The component runtime adds no
default cleanup timeout.

### Cordis comparison

Eta keeps the paper's asynchronous inertia, local activation failure, retained
error, and no unchanged-environment retry. It strengthens these rules with Eta
cancellation, settlement, and complete causes.

The Cordis paper assumes that recovery completes successfully. It does not
define a recovery operation that fails, raises, or hangs.

The TypeScript runtime logs disposer errors and continues. Eta rejects that
behavior because it can hide leaked ownership and admit a conflicting
generation.

### Prototype evidence

The accepted prototype is on branch
`prototype/eta-component-lifecycle-failure` at commit `a77e2d9b`. See the
[prototype source](https://github.com/ribelo/eta/tree/a77e2d9b8c7441565f3953ee2705a06420d5efa1/.scratch/eta-component-runtime-lifecycle-failure).

The fixed traces covered target changes during activation and settlement,
local typed failure, explicit retry, target-change retry, retirement,
interruption, and failed cleanup. They showed no overlapping generations.

The failed-cleanup trace kept the complete suppressed cause, quarantined only
the failed instance, marked the context degraded, and kept an unrelated sibling
active.
