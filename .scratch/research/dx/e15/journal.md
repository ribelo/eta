# DX-E15 Journal

Branch: `research/dx-e15-interruptible`

## Sealed predictions

Sealed before any DX-E15 executable probe or implementation change. These
predictions are immutable; later findings and scoring are appended separately.

### Substrate predictions

1. **Native Eio protection is a subtree barrier.** Inside
   `Eio.Cancel.protect`, `Eio.Cancel.sub` creates an unprotected child of the
   protected context, not a restoration of the context outside `protect`.
   Cancelling the original parent will stop at the protected context and will
   not cancel that sub-context.
2. **Native explicit sub-cancellation still escapes.** If code explicitly
   cancels the sub-context created inside `protect`, a cancellable wait in that
   sub-context will raise `Cancel.Cancelled` through the outer protection.
   Protection blocks propagation from its parent; it does not catch arbitrary
   cancellation raised by a descendant.
3. **Native parent cancellation remains pending.** Eio's `protect` does not
   check its old parent on exit. The pending parent cancellation will be seen by
   a later cancellation check/checkpoint after the old context is restored,
   rather than necessarily at the return edge of `protect` itself.
4. **jsoo protection is an effective-depth mask.** Nested protection increments
   `fiber_protect_depth`; cancellation records `cancel_reason` but is delivered
   only when depth is zero. The current implementation checks after each
   protected callback, so only the exit that returns depth to zero delivers a
   pending cancellation. A protected unresolved await cannot be interrupted.
5. **jsoo can express innermost-wins locally.** An interruptible region can save
   a positive protection depth, make the effective depth zero, and restore the
   saved depth on exit. A nested `uninterruptible` then raises effective depth
   from zero and wins locally. Entry/exit checks will be needed to avoid losing
   cancellation at the transitions.

### Checkpoint predictions

- Core checkpoints will be `Effect.yield`, `Effect.sleep`/clock sleeps,
  runtime promise awaits (including the `Effect.async` park and
  `Effect.never`), and blocking runtime-stream operations.
- Eta channel, queue, semaphore, and signal waits will be checkpoints where
  they reduce to runtime promise/stream awaits. Immediate/nonblocking paths
  will not be checkpoints merely because the operation has a blocking sibling.
- Native blocking services inherited from Eio (including network accept and
  I/O, mutex/condition waits, and service-specific promise/stream waits) will be
  cancellable according to Eio's current cancellation context. jsoo host waits
  will be checkpoints only where their CPS continuation registers a cancellation
  waiter.
- `Effect.async` registration remains protected; its park is interruptible and
  its optional canceler remains protected.

### Mask-model and gate predictions

- The public model can be stated simply only as an innermost-wins dynamic mask:
  outside a mask `interruptible` is identity; inside one it restores parent
  cancellation at documented checkpoints; a nested `uninterruptible` masks
  again. Delivery is one-shot because the backend cancellation context retains
  one reason and each wait has one winning continuation.
- jsoo should admit that model with backend-local mask state. Native Eio will
  not admit it through `Cancel.protect` plus `Cancel.sub` alone. It will require
  either a new backend operation that can restore the context outside the
  protected subtree, or a relay fiber that observes original-parent
  cancellation and explicitly cancels interruptible descendants.
- A relay construction is predicted to introduce publication/removal races at
  mask entry and exit and to complicate blocking-service semantics beyond the
  roughly twelve-line interface budget. Unless probes reveal an existing Eio
  restoration mechanism, the predicted recommendation is **KILL** rather than
  ship a partially interruptible or lossy model.
- If promoted despite that prediction, the expected public census delta is one
  top-level `Effect` combinator and no application call-site migration. A new
  contract operation would also add one backend obligation. If killed, the
  public API delta is zero and the durable DX delta is the checkpoint list.

### Finalizer prediction

`interruptible` is not allowed to restore cancellation in Eta finalizers.
Finalizers run under protection so cleanup can settle after interruption;
restoring there would permit re-entrant cancellation to abort the cleanup that
the protection exists to guarantee. The predicted answer matches ZIO: **no**.

### Adversarial predictions

- Cancel-before-restore and cancel-during-restore-entry are the likely lost-
  wakeup boundaries. A valid construction must make pending cancellation
  observable before installing any cancellable park.
- Cancel-between-restore-and-exit must either interrupt the region or remain
  pending for the next outer interruptible checkpoint; it must not disappear
  when dynamic mask state is restored.
- Nested masks should be distinguishable only by the innermost active mask
  frame. In particular,
  `uninterruptible (interruptible (uninterruptible e))` should observe the same
  cancellation behavior as `uninterruptible e`.
- Delivery must be claimed once when cancellation races a successful wake; any
  design that can both return the wake result and later replay the same
  cancellation as a second delivery fails the gate.
