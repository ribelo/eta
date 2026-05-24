---
id: Eta-lo9
title: "P1: Semaphore.acquire leaks permits on cancellation race with wakeup"
status: closed
priority: 1
issue_type: bug
created_at: 2026-05-24T12:50:24.318Z
created_by: backlog
updated_at: 2026-05-24T15:19:28Z
closed_at: 2026-05-24T15:19:28Z
close_reason: Fixed — semaphore wakeup is two-phase and cancelled unclaimed
  waiters return permits; regression test added.
dependencies:
  - issue_id: Eta-lo9
    depends_on_id: Eta-4ob
    type: parent-child
    created_at: 2026-05-24T12:50:30.092Z
    created_by: backlog
---

# P1: Semaphore.acquire leaks permits on cancellation race with wakeup

## description

Bug: Semaphore.acquire can consume permits for a waiter that gets cancelled between wakeup (state=Resolved, permits decremented) and the waiter's Promise.await returning. The cleanup handler at semaphore.ml:88-95 only handles Waiting state; Resolved and Cancelled do nothing. The public API (semaphore.mli:22-36) explicitly documents acquire as cancellation-safe: no permits consumed if cancelled. That contract is violated.

Location: packages/eta/semaphore.ml:45-57, 72-102

## design

Two-phase commit. States: Waiting | Resolved_unclaimed | Claimed | Cancelled. On wakeup (wake_waiters_locked), move to Resolved_unclaimed and decrement permits. After Promise.await, atomically claim. If cancellation cleanup sees Resolved_unclaimed, return permits and wake subsequent waiters. Or move acquisition + release registration into a single runtime primitive.

RED test: create semaphore with permits=1, spawn fiber A that acquires, spawn fiber B that acquires (blocks), resolve A's permit, cancel B while B's waiter is in Resolved state, assert available=1 (permit returned).

## acceptance criteria

RED test passes: cancelled waiter after wakeup returns permit. Existing pool/h2-admission tests pass unchanged. Semaphore.acquire remains cancellation-safe under timeout and Supervisor.scoped cancellation.
