---
id: Effet-4y2
title: "A4: Cross-fiber span propagation via Eio.Fiber.create_key"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T11:51:53.103Z
created_by: backlog
updated_at: 2026-05-19T12:32:46.221Z
closed_at: 2026-05-19T12:32:46.221Z
close_reason: Added Eio.Fiber active-span propagation for interpreted spans;
  tests cover par, all, for_each_par, detach, cancelled child, and
  uninterruptible child status. Full suite passes (56 tests).
dependencies:
  - issue_id: Effet-4y2
    depends_on_id: Effet-dsd
    type: parent-child
    created_at: 2026-05-19T11:53:15.374Z
    created_by: backlog
  - issue_id: Effet-4y2
    depends_on_id: Effet-0mf
    type: blocks
    created_at: 2026-05-19T11:53:39.565Z
    created_by: backlog
---

# A4: Cross-fiber span propagation via Eio.Fiber.create_key

## description

Detached fibers and parallel children must inherit their parent's active span at fork time so the trace tree stays correct. Without this, a parallel child opens a top-level span instead of nesting under its caller. This task wires Eio's fiber-local storage so the active span context propagates across forks.

## design

Use Eio.Fiber.create_key to hold the active span stack per fiber. The interpreter sets/binds the key when entering a span and reads it when forking via detach, par, all, for_each_par, and the race internals. Fork sites pass the current span context to the child fiber's interpretation. The Tracer module remains stack-based for the calling fiber; cross-fiber inheritance happens at the runtime layer, not inside Tracer itself. Verify behavior with multi-fiber tests that fork during an open parent span and assert child spans carry the parent's span_id.

## acceptance criteria

An effect that calls Effect.par on two children inside a parent Named span produces three spans where both children's parent_id equals the parent span's id. The same property holds for Effect.all, Effect.for_each_par, and Effect.detach. A child span outlives an interrupted parent only if the child was wrapped in Effect.uninterruptible; otherwise the child receives status Cancelled. Tests cover all four fork sites (par, all, for_each_par, detach) and verify topology + status.
