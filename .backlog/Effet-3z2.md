---
id: Effet-3z2
title: "Tests: uninterruptible edge cases (nested masking, blocking finalizer,
  timeout-inside-protected, race losers without checkpoints)"
status: open
priority: 3
issue_type: task
created_at: 2026-05-19T18:43:31.434Z
created_by: backlog
updated_at: 2026-05-19T18:47:53.849Z
dependencies:
  - issue_id: Effet-3z2
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:47:53.849Z
    created_by: backlog
---

# Tests: uninterruptible edge cases (nested masking, blocking finalizer, timeout-inside-protected, race losers without checkpoints)

## description

Review 1 finding #9. The current Effect.uninterruptible test set covers race-loser cancellation deferral. It does not test:
- nested uninterruptible regions (does the inner mask add or override?)
- finalizers that may block during protected regions (Eio docs warn against this)
- Effect.timeout placed inside an uninterruptible region (does the timeout still fire?)
- race losers whose protected work never reaches a yield point (does cancellation deadlock the race?)

These are not feature requests; they are coverage gaps that would surface real semantic decisions. Without the tests, refactoring uninterruptible could silently break behaviour users assume.

## design

packages/effet/test/test_effet.ml gains a small Uninterruptible-edge-cases group:

1. Nested: Effect.uninterruptible (Effect.uninterruptible body) — confirm body runs without re-cancellation.
2. Blocking finalizer inside uninterruptible: an acquire_release whose release Effect.delay (Duration.ms 1000) completes the delay before the parent race finishes, even if the race already has a winner.
3. Timeout-inside-protected: Effect.uninterruptible (Effect.timeout (Duration.ms 50) (Effect.delay (Duration.ms 100) Effect.unit)) — does the timeout fire?
4. Race-loser without checkpoint: a protected loser running pure CPU-bound work (no Effect.delay, no IO, just Effect.sync that loops 1B times) — confirm cancellation is deferred until the loser returns and the race result is preserved.

Each test asserts on observable outcome (timing, cause, value), not on internal state.

Document any surprising findings as journal notes; if a real semantic gap surfaces (e.g. timeout-inside-protected needs special handling), capture as a follow-up implementation task.

## acceptance criteria

Four new tests pass under nix develop -c dune runtest --force, OR are recorded as expected-failures with a journal note explaining the semantic gap. journal.md gains a short Uninterruptible-edge-cases paragraph documenting observed behaviour for each fixture. If gaps surface, follow-up tasks are created. 1h time budget.
