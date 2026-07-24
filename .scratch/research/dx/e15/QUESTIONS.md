# DX-E15 review questions

## Inside `uninterruptible`, when can this fiber be cancelled?

Only while the current fiber is dynamically inside `Effect.interruptible`.
Cancellation already pending for the nearest mask is raised at restoration
entry. Cancellation arriving while the restored body is blocked wakes that
checkpoint. Cancellation made pending by successful synchronous tail work is
raised at the restored region's successful exit edge.

Restoration listens to both the mask-entry parent and the fiber's current
cancellation context when it enters `interruptible`. Therefore a same-fiber
`cancel_sub` created inside the mask remains able to cancel a restored block;
when sources compete, the reason from the first cancellation call executed wins
and delivery is at most once.

A nested `Effect.uninterruptible` masks again and installs the restoration that
its own nested `Effect.interruptible` will use. Outside a mask,
`Effect.interruptible` is identity.

Masks cover children, but restoration is fiber-local. A child forked inside the
mask remains masked against ancestor cancellation and does not inherit the
parent's restore closure. Direct failure of the child's own structured scope
still interrupts it, preserving fail-fast.

## Does restoration fork?

No. Both backends keep the same runtime fiber identity. The native backend moves
the current Eio fiber into the mask-entry switch context and back while a
synthetic fiber context synchronously observes cancellation of the entry-time
current context. The CPS backend changes only the current fiber's effective
protection depth. The Signal lane re-entry test proves a fiber-owned protocol
remains reentrant. The restore binding is never copied into a child or daemon.

## What do daemons inherit from a mask?

Neither restoration nor cleanup-forbidden state. Daemons are independent work:
they start outside the caller's mask, and a later mask in the daemon installs
and restores its own cancellation state normally.

## Can cleanup opt back into interruption?

No. Eta binds restoration-forbidden state before protecting finalizers,
`finally` cleanup, and asynchronous cancelers. An `Effect.interruptible` nested
there remains protected, including when cleanup inherited a restore from an
enclosing mask.

## What implementation risk remains?

The native adapter relies on hidden Eio switch, cancellation, and fiber-context
operations in one private Eta backend module. Eio is pinned in this repository,
but every Eio upgrade must revalidate the same-fiber move, synchronous observer,
and switch-boundary behavior. Upstream exposure of the needed primitives is a
human-owned external follow-up.

## What should reviewers run?

- the two Phase 0 substrate probes;
- the accept-loop victim in `probes/accept_loop_victim.ml`;
- `test/core_common/effect_interruptible_shared.ml` on native and jsoo;
- `test/signal/lane/test_eta_signal_lane.ml` for fiber identity;
- the full Nix gates recorded in `report.md`.
