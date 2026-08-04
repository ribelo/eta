# Observer delivery contract

Type: grilling
Status: open
Blocked by: 04, 06, 09, 10

## Question

What observer delivery order does Eta Signal promise?

Choose between deterministic identity order and deterministic topological order.
Define same-signal ordering, unrelated-root ordering, dynamic-bind changes,
event collection, fail-fast delivery, retries, coalescing, disposal, and the
snapshot visible to every callback.

The relation must be a total order. If dependency order is public law, the
design must compute one delivery plan instead of using pairwise reachability.
Resolve N3 and the observer-order claims in the current PRD.
