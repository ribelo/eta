---
id: Eta-44a
title: "P2: Daemon failures surface to a runtime diagnostic sink"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-24T09:06:19.326Z
created_by: backlog
updated_at: 2026-05-24T11:54:09.787Z
closed_at: 2026-05-24T11:54:09.787Z
close_reason: Fixed — part of code review remediation commit (44f46a7)
dependencies:
  - issue_id: Eta-44a
    depends_on_id: Eta-1lf
    type: related
    created_at: 2026-05-24T09:19:56.699Z
    created_by: backlog
---

# P2: Daemon failures surface to a runtime diagnostic sink

## description

Bug: packages/eta/runtime.ml fork_internal (line ~1054) wraps the daemon body in 'try ... with _ -> ()', swallowing typed failures, defects, interrupts, and compound causes. Resource.auto's refresh daemon records typed refresh failures itself, but unchecked defects are still dropped at this catch-all. Daemon failures are currently invisible to consumers and to observability backends.

Note: The orphaned ~finalizers:(ref []) inside fork_internal is the same root cause as the top-level Runtime.run finalizer leak — the finalizer drain is covered by the P1 finalizer-drain task. This task focuses on failure diagnostics specifically.

Location: packages/eta/runtime.ml fork_internal (line ~1054)

## design

RED test (write first):
1. Build a daemon effect that, after a small delay, raises Failure 'daemon crash' (or Effect.fail typed-error).
2. Spawn it via the public daemon-spawning path.
3. After waiting for the daemon to run, assert the failure is observable through some channel: a runtime diagnostic sink, an attached Cause.t list, or a captured tracer event with severity error.
4. Currently no such channel exists; the failure is invisible.
   (If the public surface for observing daemon failures has to be designed first, this red test guides the API shape.)

Regression checks:
- Eio.Cancel.Cancelled during shutdown is not surfaced as a diagnostic (interrupts are normal).
- Resource.failures continues to capture typed refresh failures.

Fix shape:
- Replace 'with _ -> ()' with a cause-capturing branch that records the failure to a runtime-internal diagnostic sink. Emit a tracer event with severity error and the cause structure.
- Decide whether to expose a public Runtime.daemon_failures or fold into existing observability (logger + tracer event). Lean on existing observability when possible.

## acceptance criteria

RED test fails on current code and passes after the fix. Resource.failures regression holds. Cancellation noise filter holds.
