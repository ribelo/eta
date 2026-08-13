# Incremental and Bonsai publication semantics

Type: research
Status: open
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
