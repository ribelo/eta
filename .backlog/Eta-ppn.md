---
id: Eta-ppn
title: "P1: Pool expiry over-releases capacity semaphore, violating max_size"
status: closed
priority: 1
issue_type: bug
created_at: 2026-05-24T12:50:24.620Z
created_by: backlog
updated_at: 2026-05-24T15:19:28Z
closed_at: 2026-05-24T15:19:28Z
close_reason: Fixed — idle expiry cleanup no longer over-releases pool capacity
  permits; regression test added.
dependencies:
  - issue_id: Eta-ppn
    depends_on_id: Eta-4ob
    type: parent-child
    created_at: 2026-05-24T12:50:30.398Z
    created_by: backlog
  - issue_id: Eta-ppn
    depends_on_id: Eta-lo9
    type: blocks
    created_at: 2026-05-24T12:50:34.861Z
    created_by: backlog
---

# P1: Pool expiry over-releases capacity semaphore, violating max_size

## description

Bug: In acquire_entry (pool.ml:357-372), a caller acquires 1 semaphore permit. reserve (pool.ml:174-196) scans idle entries, returns `Close_expired expired` if any exist. close_entries calls mark_closed for each expired entry, which decrements total and releases 1 semaphore permit per entry. If a single caller acquired 1 permit but closes N expired idle entries, it releases N permits while continuing the acquisition loop. Semaphore.release clamps to capacity at semaphore.ml:65.

Location: packages/eta/pool.ml:174-196, 213-218, 357-372

Impact: Under idle-expiry churn, the pool can open or check out more than max_size connections.

## design

Separate idle-expiry cleanup from resource-checkout reservation. Either close expired entries outside the checked-out semaphore permit, close at most one expired entry per acquired permit, or make idle entries not occupy semaphore permits (model capacity with a single authoritative total invariant).

RED test: pool with max_size=2, max_idle=2, idle_lifetime=1ms, open 2 connections then release both (become idle), wait past idle_lifetime, then spawn 4 concurrent acquirers — at most 2 should hold connections simultaneously.

## acceptance criteria

RED test passes: pool never exceeds max_size concurrent checkouts. Existing pool tests pass unchanged.
