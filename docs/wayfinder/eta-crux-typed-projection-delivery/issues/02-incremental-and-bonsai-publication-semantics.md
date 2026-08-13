# Incremental and Bonsai publication semantics

Type: research
Status: resolved
Blocked by: none

## Question

Which Jane Street Incremental and Bonsai observation semantics can inform Eta
Crux typed projection delivery?

Use current primary documentation and source code. Cover
`Observer.on_update_exn`, `Initialized`, `Changed`, `Invalidated`, notification
frequency, observer disposal, and after-stabilization callback order.

Also cover `Value.cutoff`, `Edge.on_change`, related edge operations, dynamic
activation, lifecycle, and stabilized result rendering or observation.

For each mechanism, record the publication trigger, initial replay, removal,
batching, order, backpressure, reconnection, latest-value owner, transferable
semantics, and non-transferable semantics.

## Answer

The [research report](../../../../.scratch/research/eta-crux-typed-projection-delivery/incremental-and-bonsai-publication-semantics.md)
records the full evidence and source revisions.

Incremental separates recompute from observation with a stabilization fence.
`Observer.on_update_exn` runs at most once per observer for each stabilization.
It distinguishes `Initialized`, `Changed`, and terminal `Invalidated` updates.
Explicit disposal stops later callbacks. `Observer.value_exn` exposes the latest
stable value through pull observation.

Bonsai uses the same Incremental cutoff inside its graph. A cutoff stops
downstream work. It is not a switch for root-output delivery.
`Edge.on_change` runs on first activation and at most once per frame. It receives
the latest value. Bonsai lifecycle order places `before_display` before result
work, then deactivation, activation, and `after_display`.

Eta Crux can transfer these patterns:

- stabilize before publication.
- coalesce changes into one notice for each commit.
- distinguish the first snapshot from later changes.
- use explicit disposal.
- keep cutoff inside the graph.
- combine a change notice with latest-value pull.
- run post-commit lifecycle work after result publication.

Eta Crux cannot transfer unbounded synchronous callbacks, finalizer-based close,
independent observer streams, or application effects as transport delivery.
These mechanisms lack Eta Crux acknowledgment and capacity contracts.

The public text and source do not give one clear rule for equal-value
`Edge.on_change` reactivation. The later design must not use that behavior as a
contract.
