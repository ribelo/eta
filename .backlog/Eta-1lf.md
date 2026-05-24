---
id: Eta-1lf
title: "P1: Drain finalizers at every Runtime.run boundary (acquire_release leak)"
status: closed
priority: 1
issue_type: task
created_at: 2026-05-24T09:03:27.214Z
created_by: backlog
updated_at: 2026-05-24T11:54:09.787Z
closed_at: 2026-05-24T11:54:09.787Z
close_reason: Fixed — runtime.ml wraps top-level interpret and daemon bodies in
  with_finalizers (44f46a7)
---

# P1: Drain finalizers at every Runtime.run boundary (acquire_release leak)

## description

Bug: packages/eta/runtime.ml Runtime.run (line ~1133) creates 'let finalizers = ref []' and calls interpret directly. with_finalizers (line ~371) is invoked only inside Scoped and Supervisor_scoped interpreter cases. As a result, a top-level Effect.acquire_release pushes a release closure that is never drained — release effect never runs. The same orphaned-finalizers-ref pattern repeats in fork_internal (line ~1054) for daemon bodies, so acquire_release inside daemons leaks too. Effect.acquire_release is documented public API; it must be safe at the runtime root and inside daemons.

Locations:
- packages/eta/runtime.ml Runtime.run (line ~1133)
- packages/eta/runtime.ml fork_internal (line ~1054)

## design

RED test (write first):
1. let released = ref false in
   Runtime.run rt (Effect.acquire_release ~acquire:Effect.unit ~release:(fun () -> Effect.sync (fun () -> released := true)))
   Assert !released after run. Currently fails.
2. Same shape but inside an Effect.daemon body that completes normally; assert release ran after the daemon finishes.
3. Cancellation variant: top-level acquire_release whose body raises a typed failure. Assert release still ran.

Fix shape:
- Wrap the top-level interpret inside Runtime.run in with_finalizers ~runtime ~fail_key finalizers (fun () -> ...) so finalizers drain on success and failure.
- Apply the same wrapping inside fork_internal.
- Update acquire_release docstring to confirm root-scope safety.

## acceptance criteria

All three RED tests fail on current code and pass after the fix. Existing Effect.scoped tests still pass (no double-drain). The same fix covers daemons; no separate code path needed.
