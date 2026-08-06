# Node identity and index lifecycle

Type: prototype
Status: resolved
Blocked by: 07

## Question

How can dense node indices survive invalidation and reuse without letting a stale
index name a different node?

The selected rollback journal records indices, not pointers. Compare monotonic
indices with tombstones, a free list with a generation check, and other
qualifying schemes.

The selected scheme must keep the four-word static path, must keep the O(1)
commit, and must bound the retained node table for a graph that creates and
invalidates nodes for a long time.

## Answer

Use a reusable dense slot table with an integer generation in each slot.
Long-lived handles contain the slot and generation. Lookup compares both
integers.

Quarantine each slot that the current pass retires. The allocator can reuse
slots that were free before the pass. It cannot reuse a quarantined slot.

Active rollback journals can continue to store slot integers. A slot cannot
change incarnation during the pass. Commit resets the active journal length in
O(1), and the next pass overwrites the stale prefix before use.

Run affected-only lifecycle cleanup after commit and before callbacks. Cleanup
clears pointer-bearing actions and moves committed retirements to the free list.
Pending cleanup blocks a new pass and quiescent allocation.

Check the pass identity before a pass starts. Fail with the documented counter
error before the identity can wrap.

Candidate B keeps static allocation at 4 words. Its largest prototype
wall-time ratio against Incremental is 0.504.

Reject monotonic tombstones because retention grows with historical churn.
Reject epoch compaction because it scans the live table.

The prototype, complete measurements, retention checks, rollback order, and
issue 08 constraints are in
[Node identity and index lifecycle](../../../../.scratch/research/eta-signal-execution-model/node-identity-and-index-lifecycle.md).
