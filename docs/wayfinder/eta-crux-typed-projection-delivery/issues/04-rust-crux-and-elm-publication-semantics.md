# Rust Crux and Elm publication semantics

Type: research
Status: resolved
Blocked by: none

## Question

Which Rust Crux and Elm publication semantics can inform Eta Crux typed
projection delivery?

Use current primary documentation and source code. For Rust Crux, cover view
projection, render notification, serialized bridge behavior, and
notification-then-pull.

For Elm, cover whole-program view publication, subscriptions, ports, and the
presence or absence of a per-projection observation contract.

For each mechanism, record its trigger, initial replay, removal, batching,
order, backpressure, reconnection, latest-value owner, transferable semantics,
and non-transferable semantics.

## Answer

The [research report](../../../../.scratch/research/eta-crux-typed-projection-delivery/rust-crux-and-elm-publication-semantics.md)
records the full evidence and source revisions.

Rust Crux separates a payload-free render notice from a later view pull. The
shell pulls one complete view model. Each pull recomputes the view from the
current model. The serialized bridge returns one request batch for each core
call and gives requests ascending, non-reused identifiers.

Rust Crux has no render acknowledgment, serialized session, retained view
snapshot, or documented effect order. Its channels are unbounded.

Elm publishes one whole-program view. The browser runtime draws the initial
model, then coalesces later draws by animation frame. The runtime groups each
new subscription bag by effect manager. Browser.Events and Time reconcile their
lists with manager-specific keys. Ports carry whole values and retain no latest
value.

Elm has no per-projection observation contract. `Html.lazy` can skip a subtree
diff, but it does not create an observer or delivery path.

Eta Crux can transfer notice-then-pull separation, one batch for one
advancement, non-reused request identity, and manager-local subscription
reconciliation. The driver must own the retained committed output and delivery
acknowledgment.

Eta Crux cannot transfer pull-time projection recompute, unbounded queues,
animation-frame ordering, missing session identity, missing acknowledgment, or
an undocumented concurrent-effect order.
