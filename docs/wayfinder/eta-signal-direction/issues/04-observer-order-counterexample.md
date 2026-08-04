# Observer order counterexample

Type: prototype
Status: open
Blocked by: none

## Question

Does the current observer comparator fail to define a total order on a dynamic
graph, as N3 claims?

Build the `A`, `B`, and `C` graph from the independent review. Enumerate observer
registration orders and relevant creation orders. Record comparator relations,
delivery orders, and whether any delivery violates a dependency-first promise.

Compare deterministic observer-identity order with one explicit topological
delivery plan. Do not implement either production policy. Link the prototype as
an asset.
