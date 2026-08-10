# Pull observation of root output

Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

Does Eta Crux need pull observation of the latest committed root output?

Check whether hosts must cache pushed delivery and whether all safe pull
semantics already follow from the advancement and delivery fences. Distinguish
the latest committed output from the latest successfully delivered output.

Decide whether to adopt, defer with a precise condition, or reject the
capability. If adopted, specify the API shape, availability, consistency,
concurrency, lifetime, failure, laws, test controls, ownership, and migration
effects.

## Answer

### Decision

Adopt pull observation of the latest committed root output. `Driver` owns the
capability:

```ocaml
val latest_committed_output : 'output t -> 'output option
```

This synchronous query returns no commit identity, delivery state, or terminal
state. It does not fail or wait.

The latest committed output is the complete root output from the most recent
successful advancement. The latest delivered output is the most recent output
whose delivery token the host accepted.

### Availability and lifetime

The query returns `None` before the first commit. After each commit, it returns
`Some` with the complete output of that commit, including an output equal to the
prior output.

A pending delivery does not hide the new committed output. Successful delivery
does not change it. Delivery failure cannot roll back it.

The driver retains the output after delivery failure, normal stop, or crash.
The output remains available while the driver value remains reachable.

### Consistency and concurrency

The query is linearizable with driver operations. If a query overlaps commit
publication, it returns the previous or new complete output. It never returns a
staged or partial output.

The query does not answer a delivery token. It does not start post-commit work
or suppress mandatory push delivery.

### Ownership

The driver owns retention of the latest committed output. It does not retain a
second snapshot for the latest delivered output.

Adapters own delivery, reconciliation, and any delivered-output retention that
their host contract requires. A host does not need a separate cache when it
only needs the latest committed application state.

### Test surface

The test handle exposes both observation boundaries:

```ocaml
val latest_committed_output :
  ('output, 'incoming) t -> 'output option

val latest_delivered_output :
  ('output, 'incoming) t -> 'output option
```

`latest_committed_output` uses the production driver query.
`latest_delivered_output` keeps the current successful-delivery boundary.
Test injection continues to use the latest delivered output.

No new clock or scheduler control is necessary. Existing low-level driver and
delivery controls can hold a delivery pending, accept it, or fail it.

### Laws and gates

The accepted contract adds these laws:

- Before the first commit, the latest committed output is absent. Each commit
  atomically replaces it with one complete output.
- Delivery state, delivery outcome, post-commit work, stop, and crash do not
  replace or clear the latest committed output.
- A pull concurrent with commit publication observes the complete output before
  or after that publication. It observes no other value.
- A pull has no delivery or post-commit effect.
- The delivered output of the test handle changes only after successful delivery.
  Test injection uses that delivered output.

The implementation effort adds these named gates:

- `qcheck_latest_committed_output` generates bounded commit sequences and
  terminal branches. Coverage requires initial absence, equal and unequal
  consecutive outputs, pending delivery, successful delivery, failed delivery,
  stop, and crash.
- `race_pull_vs_commit_both_winners` controls the pull and publication order. It
  observes both legal outcomes and no partial output.
- `test_pull_does_not_complete_delivery` holds a delivery pending. It proves
  that a pull does not answer the token or start post-commit work.
- `test_handle_output_boundaries` distinguishes committed output, delivered
  output, and the output that test injection uses.

The public driver query and test-handle queries form the observation boundary
for these gates.

### Migration effects

The production package adds `Driver.latest_committed_output`. It adds no
`Root` query and no delivered-output query.

The test package removes `Handle.last_output`. It adds
`Handle.latest_committed_output` and `Handle.latest_delivered_output` with no
compatibility alias. The repository has no current `Handle.last_output` caller.

Adapters can remove shadow caches that represent committed application state.
Adapters keep caches that represent successful host delivery.

The implementation effort must update the observation laws to assign committed
snapshot retention to the driver. The delivery and test-injection laws retain
their current boundaries.
