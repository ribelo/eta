---
id: Eta-18b
title: "P1: Effect.Island worker_die captures exception message and backtrace"
status: closed
priority: 1
issue_type: task
created_at: 2026-05-24T09:05:24.167Z
created_by: backlog
updated_at: 2026-05-24T11:54:09.787Z
closed_at: 2026-05-24T11:54:09.787Z
close_reason: Fixed — island_runtime.ml captures per-exception message and
  backtrace in worker_die (44f46a7)
---

# P1: Effect.Island worker_die captures exception message and backtrace

## description

Bug: packages/eta/effect.ml generic_worker_die (line ~27) is a single shared constant: { kind = 'worker_died'; message = 'portable island callback raised'; backtrace = None }. capture_map and capture_result (line ~60) use try ... with _ -> Map_worker_died generic_worker_die — no per-exception detail. The worker_die record has fields for kind, message, backtrace, but they are never populated.

Location: packages/eta/effect.ml Island_runtime.capture_map, Island_runtime.capture_result

## design

RED test (write first):
1. Submit an island callback that raises Failure 'specific worker error'.
2. Use Effect.Island.all_settled to obtain the Worker_died die outcome.
3. Assert die.message contains the substring 'specific worker error' (or that some field carries identifying detail).
4. Assert Option.is_some die.backtrace.
5. Currently both fail — message is the generic constant.

Fix shape:
- In capture_map and capture_result, replace the catch-all with a handler that captures Printexc.to_string exn and Printexc.get_raw_backtrace () |> Printexc.raw_backtrace_to_string. Build worker_die per-call.
- Ensure no raw exn value crosses the portable boundary (only strings).

## acceptance criteria

RED test fails on current code and passes after the fix. Round-trip of a known exception class confirms the message contains identifying text. The backtrace is non-empty when capture_backtrace is enabled.
