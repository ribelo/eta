# Node identity and index lifecycle

Type: prototype
Status:
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
