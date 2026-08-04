# Atomic phase entry

Type: prototype
Status: open
Blocked by: none

## Question

Does transaction identity exhaustion reproduce N1 and leave the graph stuck in
the pure phase?

Build the smallest throwaway fault-injection probe. Force the next transaction
identity allocation to fail. Observe the returned error, stabilization state,
transaction state, and a later stabilization attempt.

Compare an integer allocator with a fresh physical token only far enough to
expose the required phase-entry invariant. Do not implement the production fix.
Link the prototype as an asset.
