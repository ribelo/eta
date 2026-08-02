# Dynamic lifetime and work ownership

Type: grilling
Status: resolved
Blocked by: 03, 05

## Question

What does activation, deactivation, and disposal mean for a dynamically selected
or keyed child computation?

Decide:

- when local state is created and when it becomes observable.
- whether temporary inactivity preserves or disposes state.
- which resources, staged effects, running effects, timers, and external sources
  belong to the child scope.
- cancellation and finalizer order on branch replacement or key removal.
- the behavior of queued actions and captured injectors after disposal.
- whether work can detach from its declaring computation.
- how a caller models work that must outlive the view or child that requested it.
- which cleanup failures remain visible after another failure.

Use Eta structured concurrency and GC deliberately. GC can reclaim unreachable
descriptions, but correctness and timely cleanup must not depend on finalizer
timing.

## Answer

### Lifetime states

Eta Crux has no inactive child state. A child is either active or disposed.
Committed absence disposes the child, including its model and endpoint
incarnation. A later appearance creates a fresh child incarnation.

The pure stabilization phase can construct provisional state. That state is not
observable. The atomic graph commit makes the child active, publishes its
output, and validates its endpoints together.

The driver delivers the committed output before starting activation work.
Therefore, child visibility does not depend on activation success or completion.

Committed removal immediately removes the child from output and makes its
endpoints stale. Cleanup remains tracked after this logical disposal. GC only
reclaims unreachable values and never defines timely cleanup.

Applications preserve state by placing it in a longer-lived parent. They can
also keep a child active while hiding its output. Eta Crux has no retained-child
cache in V1.

### Lifecycle program

The semantic lifecycle operation accepts a changing Eta effect:

```ocaml
val lifecycle : (unit, never) Eta.Effect.t t -> unit t
```

[OCaml API syntax and ergonomics](14-ocaml-api-ergonomics.md) owns the final name
and argument order.

Each lifecycle description node runs at most one scoped program during one
active interval. Activation samples the latest committed effect value and starts
it through the advancement's post-commit batch.

A later effect-value change does not restart the running program. A later active
interval samples the latest value. Applications use a dynamic child boundary
when a value change must restart lifecycle work.

Normal program completion leaves the child active and releases that program's
resources. A program that holds resources for the complete active interval
remains pending until interruption. Eta resource finalizers perform deactivation
cleanup, so Eta Crux adds no independent deactivation callback.

### Work ownership

Work follows the structural scope tree. The root owns root-level work. A dynamic
or keyed child scope owns work declared inside that child and owns its nested
child scopes.

Owned work includes transition effects, lifecycle programs, resources, timers,
and external-source consumers. Each item retains its declaring cell identity for
endpoint validation and diagnostics. Its structural scope determines
cancellation.

Eta Crux exposes no detach, promotion, or root-background operation. Work that
must outlive a child starts in a longer-lived parent. The child sends a message
to that parent's endpoint, and the parent transition starts the work.

If one transition commits disposal of its own scope, its returned effect never
starts. The owner no longer exists when post-commit transition effects become
eligible. Automatic transfer to the parent is forbidden.

### Disposal and cancellation

Starting a committed deactivation group requests cancellation for each complete
removed subtree. Nested children settle before parent finalizers. Sibling scopes
settle concurrently, and each scope keeps Eta's resource-finalizer order.

The post-commit batch calls `Supervisor.Scope.request_cancel` for each removed
subtree root in committed structural order. Every request returns before new
lifecycle programs and the current transition effect start.

A returned request does not mean settlement. Ordinary replacement does not wait
for old cleanup to finish. Old cleanup and new work can overlap after their
ordered start points. The Eta scheduler determines interruption and finalizer
order across different removed subtrees.

The runtime tracks every closing scope until its work and finalizers settle.
Pure disposal interruption is normal completion of ownership cleanup. A race
between work completion and disposal inherits Eta's first terminal outcome.

Queued messages retain the old scope incarnation. Delivery rejects them as
`Stale_endpoint`, including after same-structure or same-key re-entry. Captured
old endpoints never retarget a new child.

A failed advancement cancels no committed scope. The old child remains active,
and its endpoints remain valid because disposal did not commit.

### Failures and shutdown

Eta Crux preserves every cleanup diagnostic through `Eta.Cause`. Primary
failures remain primary. Cleanup failures remain finalizer or suppressed
diagnostics, and sibling cleanup failures retain concurrent structure.

[Failure, defect, and crash boundary](11-failure-boundary.md) defines how these
causes affect the root and reach explicit or hosted drivers.

Root shutdown uses the same ownership tree with a stronger completion fence.
The final post-commit batch interrupts the complete root subtree and waits for
all work and finalizers. Only then does the root enter `Closed`.

### Eta boundary

Eta owns effects, scopes, cancellation, resources, supervision, and failure
causes. Eta Crux owns computation structure, identity, advancement, and typed
output. If Eta Crux starts rebuilding general runtime machinery, Eta gains the
missing primitive instead.

[Eta supervised work substrate](19-eta-supervised-work-substrate.md) points to
the authoritative Eta verdict and production contract. Eta adds
`Supervisor.Scope.request_cancel`. Eta Crux composes it with existing atomic
effect registration, settlement, cause preservation, and scoped shutdown.

### Rejected alternatives

Eta Crux does not retain inactive models, assign all work to the root, or expose
detached effects. It does not create an independent work scope for every state
machine node.

Lifecycle programs do not restart after ordinary value changes. Effect
completion does not alter computation structure. Self-disposing transition
effects never receive an automatic parent lifetime.

Root closure never leaves cleanup running in the background. Eta Crux does not
discard later cleanup failures or replace structured causes with log-only
reporting.
