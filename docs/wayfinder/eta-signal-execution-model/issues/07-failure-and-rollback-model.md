# Failure and rollback model

Type: prototype
Status:
Blocked by: 01, 06

## Question

How can the kernel preserve the last committed snapshot after a fallible pass
without a universal transaction over all recomputed nodes?

Compare sparse undo, prepared publication, persistent state, and other
qualifying models against every binding failure and reentry scenario.
