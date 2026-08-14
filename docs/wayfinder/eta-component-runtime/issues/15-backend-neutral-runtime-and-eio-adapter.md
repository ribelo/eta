# Backend-neutral runtime and Eio adapter

Type: prototype
Status: resolved
Blocked by: 03, 04, 06, 11, 12, 13

## Question

Where is the seam between backend-neutral component semantics and the Eio
reference adapter?

Prototype the smallest runtime contract that can schedule lifecycle work,
await dependency-safe teardown, preserve Eta causes, and expose deterministic
test control. Compare direct Eio ownership with composition over current Eta
Runtime and Supervisor interfaces.

Do not expose Eio switches or backend runtime tokens through the public
component interface.

## Answer

Use one lexical component-context lifetime expressed as an Eta effect. This
lifetime owns one `Supervisor.scoped` nursery. Each activation generation is a
private supervisor child with one fresh `Effect.with_scope` lifetime.

The supervisor child is the Eta equivalent of the paper's private
`fiber.inertia` transition handle. It cannot escape the nursery. The component
interface does not expose the child, an Eio switch, an Eio cancellation value,
or an Eta runtime token.

`Context.run` is the provisional name for the lexical operation. The
public-interface decision can change the name and argument form. It must keep
the complete component context inside one Eta effect lifetime.

### Runtime seam

The component package adds no component-specific Eio scheduler or backend
runtime contract.

The backend-neutral component coordinator uses:

- `Effect.t` for lifecycle work.
- `Supervisor.Scope.start` for a generation transition.
- `Supervisor.Scope.request_cancel` for an interruption request.
- `Supervisor.Scope.await` for the settlement fence.
- `Effect.with_scope` for one generation's lexical resources.
- `Effect.to_exit` to materialize the complete settled cause.
- Eta queues and other Eta coordination primitives for private commands and
  completion events.

The existing Eta runtime seam remains the only backend seam. `Eta_eio`
interprets the component effect in production. `Eta_test.Run` interprets the
same effect with deterministic time, ordered observations, and a fiber census.

`Runtime.run` alone is not a lifecycle owner. It runs an effect to completion,
but it supplies no targeted child ownership, cancellation request, or
settlement handle.

Direct Eio ownership is rejected. It duplicates Eta scope, cancellation,
settlement, cause, and test-scheduling behavior. A direct adapter must also
translate Eio exceptions back into complete Eta causes.

### Generation protocol

The coordinator follows this sequence:

1. Resolve one complete provider view and create a fresh generation.
2. Start one private supervisor child for that generation.
3. Run activation inside one fresh Eta scope.
4. Admit tracked work only while the generation admission fence is open.
5. Stage the complete declared provision set.
6. Commit the staged set only when the generation still matches the target.
7. Keep the active child waiting on a private normal-stop signal.
8. On withdrawal, close admission and remove the episode from new resolution.
9. Settle consumers that retain leases for the episode.
10. Send the normal-stop signal only when the direct lease count reaches zero.
11. Await the child until its Eta scope and all finalizers settle.
12. Start a later generation only after this settlement.

A target change during activation closes admission before it requests
cancellation. Work admitted before the fence retains the landing and recovery
rules from [Temporal ownership and recovery](11-temporal-ownership-and-recovery.md).
The stale generation cannot commit.

Normal active deactivation does not use cancellation. The coordinator sends the
normal-stop signal after the withdrawal guard releases. Eta cancellation remains
an interruption path for invalidated activation and forced context shutdown.

If a dependent cleanup fails or does not terminate, its provider lease remains.
The coordinator does not send the provider's normal-stop signal. The provider
stays guarded, and the context remains degraded or nonquiescent.

### Causes and settlement

The generation child materializes its complete settled `Exit.t`. The coordinator
stores this value without converting it to an OCaml `result`, a string, or a
log-only event.

A normal stop followed by failed cleanup produces `Cause.Finalizer`. An
activation failure followed by failed cleanup produces `Cause.Suppressed`.
Requested interruption without another failure is lifecycle control. An
unexpected interruption remains part of the retained generation cause.

Repeated shutdown or disposal requests observe or join the same child
settlement. They do not start another cleanup pass.

### Cordis comparison

The paper abstracts transition scheduling as `create_task` and stores the
private handle as `fiber.inertia`. The TypeScript implementation stores a
`Promise<void>` in `Fiber.inertia`. Eta uses the private supervisor child for
the same inertial role.

The Eta context lifetime is stricter than the TypeScript object lifetime. The
complete context must remain inside `Context.run`. A context does not survive
separate top-level `Runtime.run` calls.

The normal-stop path matches Cordis deactivation. Host cancellation is an Eta
extension because the paper does not define it and TypeScript promises do not
cancel the in-flight effect.

Eta also strengthens TypeScript cleanup. Eta preserves failed cleanup in the
settled cause and runs scope finalizers serially in last-in-first-out order.
TypeScript logs disposer failures, and its `_unload` can overlap top-level
asynchronous disposers through `Promise.all`.

### Prototype evidence

The accepted prototype is on branch
`prototype/eta-component-runtime-eio-adapter` at commit `9f5a5c90`. See the
[prototype source](https://github.com/ribelo/eta/tree/9f5a5c90ecda2d3bd5b834d0085b77270a2d66b0/.scratch/eta-component-runtime-eio-adapter)
and its
[Cordis comparison](https://github.com/ribelo/eta/blob/9f5a5c90ecda2d3bd5b834d0085b77270a2d66b0/.scratch/eta-component-runtime-eio-adapter/COMPARISON.md).

The fixed traces cover prepared and committed generations, consumer-first
settlement, combined failure, and interruption after an admission fence. They
also cover deterministic replay and an empty final fiber census.

The prototype demonstrates the runtime seam and the successful withdrawal
schedule. It does not replace the provider-view, lease, lifecycle, or
reactive-resolution evidence in the prerequisite decisions.
