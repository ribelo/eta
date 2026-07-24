# DX-E15 parking lot

## `Effect.interruptible`

Status: **REVIVED by Follow-up 1; fork model corrected by Follow-up 2;
same-fiber descendant restoration corrected by Follow-up 3; cancellation-call
ordering corrected by Follow-up 4**.

The historical kill below required an exact-context same-fiber restore. Follow-up
1 found and independently reproduced Eio's hidden switch restoration operation.
E15 resumed with that operation isolated in one private backend module.

Do not reopen the combinator until the native runtime can restore or observe the
exact cancellation context outside `Eio.Cancel.protect`, including an enclosing
Eta synthetic `cancel_sub`, without polling or a scope-only relay.

Acceptable reopening evidence is one of:

1. an Eio restore operation that temporarily runs the current fiber in the
   context outside `Cancel.protect`;
2. an Eio operation that attaches a cancellable child/observer to an arbitrary
   live cancellation context; or
3. a separately approved redesign of `Runtime_contract` cancellation handles
   that gives every synthetic context lossless mask-relay notification.

Any revival must rerun the committed Phase 0 probes, publish one shared
innermost-wins model, retain the checkpoint list, keep finalizers protected, and
add the named native and jsoo mask/race laws before exposing the API.

All of those revival conditions are addressed in `report.md`. Follow-up 3 added
an asynchronous scoped observer as a supplement to exact restoration; Follow-up
4 replaced it with a synthetic Eio fiber context whose cancellation function
forwards synchronously. `run_in` observes the mask-entry parent directly, and
the synchronous hook preserves cancellation-call ordering. The remaining
parking-lot item is the human-owned request for Eio to expose the required
switch/cancellation/fiber-context operations publicly; external issue filing is
outside programme scope.


## Child restoration across a parent mask

Status: **OUT OF E15 SCOPE**.

E15 restoration is fiber-local. A future combinator that restores cancellation
inside a forked child cannot inherit or invoke the parent's restore closure: it
must listen to both parent cancellation at the mask-entry context `R` and direct
fail-fast cancellation of the child's own context `Q`, select exactly one
winner, and avoid lost wakeups across entry, blocking, and exit. Revisit only
with a backend-neutral multi-context observation primitive and adversarial proof
on both substrates. Follow-up 3 solves the distinct same-fiber descendant
topology; it does not make restoration fork-inheritable.
