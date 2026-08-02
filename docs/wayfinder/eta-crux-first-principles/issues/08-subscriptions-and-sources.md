# Long-lived sources and subscriptions

Type: grilling
Status: open
Blocked by: 05, 07

## Question

Does Eta Crux need a first-class subscription concept, or do scoped Eta effects
and streams already express every required long-lived source?

Compare at least:

- one lifecycle program that runs a scoped stream-consumer effect.
- Elm-style desired subscriptions derived from committed computation state.
- keyed source declarations reconciled by identity.
- host-owned sources that start and stop through an adapter protocol.

Decide identity, update, restart, failure, item injection, cancellation, and
shutdown semantics. Include the race where a transition both declares a source
and stages the effect that can emit its first item. Avoid a framework concept if
Eta `Resource`, `Stream`, and scoped effects already supply the same invariant.
