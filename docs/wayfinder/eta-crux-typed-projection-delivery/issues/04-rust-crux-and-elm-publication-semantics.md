# Rust Crux and Elm publication semantics

Type: research
Status: open
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
