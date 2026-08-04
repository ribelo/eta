# Keyed removal with a nested bind switch

Type: prototype
Status: open
Blocked by: none

## Question

Does one stabilization that removes a keyed child and switches its nested bind
reproduce N2?

Build the smallest public graph from the independent review. Observe owner and
scope validity, committed bind state, dependent edges, provisional-scope
cleanup, pending transaction work, and retained node counts. Include a new
branch that points to a top-scope signal.

Vary planning and commit order only in the throwaway prototype. Use the result
to identify the invalidation-closure invariant. Do not implement the production
fix. Link the prototype as an asset.
