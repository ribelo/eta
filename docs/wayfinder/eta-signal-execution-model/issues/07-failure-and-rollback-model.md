# Failure and rollback model

Type: prototype
Status: resolved
Blocked by: 01, 06

## Question

How can the kernel preserve the last committed snapshot after a fallible pass
without a universal transaction over all recomputed nodes?

Compare sparse undo, prepared publication, persistent state, and other
qualifying models against every binding failure and reentry scenario.

## Answer

A sparse undo journal preserves the committed snapshot. It needs no universal
transaction.

Each node keeps one undo slot and one write stamp. A pass records a node once, at
its first write. Commit resets the journal length in O(1). Rollback walks the
journal in reverse.

The journal records dense node indices, not node pointers. Indices avoid the
pointer write barrier and cost 1.0 nanoseconds for each changed node instead of
3.9 nanoseconds.

A failed pass also drains the height buckets and replays a retained admission
frontier. Source work therefore stays retryable.

The candidate allocates 4 words at changed depths 1, 10, and 100, which equals
the issue 06 result. Its largest static wall-time ratio against Incremental is
0.769. One failed pass with its retry allocates 8 words, against 1,227 to 11,919
words for the pinned Eta reference.

Reject prepared publication for the static path. It walks the written set on
every changed pass and needs two read modes.

Reject lazy epoch rollback. A monotonic committed counter cannot separate a
committed stamp from an abandoned stamp, because a later admission can suppress
propagation through a node that the failed pass overwrote.

Reject persistent state. Issue 06 measured its depth-dependent allocation.

The rollback journal allocates nothing, but it is not free. It costs 1.0 to 1.5
nanoseconds for each changed node. That cost is the price of SB10.

The prototypes, complete measurements, scenario census, limits, and inherited
constraints are in
[Failure and rollback model](../../../../.scratch/research/eta-signal-execution-model/failure-and-rollback-model.md).
