# DX-E15 review questions

## Inside `uninterruptible`, when can this fiber be cancelled?

Only while the current fiber is dynamically inside `Effect.interruptible`.
Cancellation already pending for the nearest mask is raised at restoration
entry. Cancellation arriving while the restored body is blocked wakes that
checkpoint. Cancellation made pending by successful synchronous tail work is
raised at the restored region's successful exit edge.

A nested `Effect.uninterruptible` masks again and installs the restoration that
its own nested `Effect.interruptible` will use. Outside a mask,
`Effect.interruptible` is identity.

## Does restoration fork?

No. Both backends keep the same runtime fiber identity. The native backend moves
the current Eio fiber into the mask-entry switch context and back. The CPS
backend changes only the current fiber's effective protection depth. The Signal
lane re-entry test proves a fiber-owned protocol remains reentrant.

## Can cleanup opt back into interruption?

No. Eta binds restoration-forbidden state before protecting finalizers,
`finally` cleanup, and asynchronous cancelers. An `Effect.interruptible` nested
there remains protected, including when cleanup inherited a restore from an
enclosing mask.

## What implementation risk remains?

The native adapter relies on a hidden Eio implementation module in one private
Eta backend module. Eio is pinned in this repository, but every Eio upgrade must
revalidate the same-fiber move and switch-boundary behavior. Upstream exposure
of the primitive is a human-owned external follow-up.

## What should reviewers run?

- the two Phase 0 substrate probes;
- the accept-loop victim in `probes/accept_loop_victim.ml`;
- `test/core_common/effect_interruptible_shared.ml` on native and jsoo;
- `test/signal/lane/test_eta_signal_lane.ml` for fiber identity;
- the full Nix gates recorded in `report.md`.
