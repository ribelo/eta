# DX-E15 parking lot

## `Effect.interruptible`

Status: **KILLED on the current substrates**.

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
