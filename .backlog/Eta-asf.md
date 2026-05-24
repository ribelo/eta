---
id: Eta-asf
title: "P1: Schedule.and_then must offset step for the second schedule"
status: closed
priority: 1
issue_type: task
created_at: 2026-05-24T09:03:43.775Z
created_by: backlog
updated_at: 2026-05-24T11:54:09.787Z
closed_at: 2026-05-24T11:54:09.787Z
close_reason: Fixed — driver rewrite solves and_then step offset; schedule.ml
  now stateful (44f46a7)
---

# P1: Schedule.and_then must offset step for the second schedule

## description

Bug: packages/eta/schedule.ml next_delay is stateless over a global step:int. And_then (a, b) (line ~70) queries 'b ~step' with the same step counter once 'a' returns None. Linear and Exponential schedules under 'b' therefore see step counts already advanced through 'a' span. After recurs 5, Exponential(1s, factor:2.0) queried at step 5 returns 32s instead of the intended 1s. This affects every retry/repeat policy that composes backoff phases via and_then.

Location: packages/eta/schedule.ml And_then case in next_delay

## design

RED test (write first):
1. Build s = and_then (recurs 5) (exponential ~factor:2.0 (Duration.seconds 1)). Walk steps 0..10 calling next_delay.
   Assert: steps 0..4 return Some Duration.zero, step 5 returns Some (Duration.seconds 1), step 6 returns Some (Duration.seconds 2), step 7 returns Some (Duration.seconds 4).
   Currently step 5 returns Some (Duration.seconds 32).
2. Build s = and_then (recurs 3) (linear ~initial:(Duration.ms 100) ~step:(Duration.ms 50)). Assert step 3 returns 100ms, step 4 returns 150ms.
3. Compose with jittered: assert jittered (and_then a b) still wraps the right phase.

Fix shape:
- Replace stateless next_delay with a stateful schedule driver: type driver; val start : ?random -> t -> driver; val next : driver -> (Duration.t * driver) option.
  Or have next_delay return (Duration.t * t) option so the schedule advances itself.
- Update repeat_eff, retry_eff, Retry.schedule_delay, and any other call sites.

## acceptance criteria

All three RED tests fail on current code and pass after the fix. All existing schedule tests still pass. jittered wraps the driver, not a stateless function.
