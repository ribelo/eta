---
id: Eta-3k8
title: "P1: Plumb a clock into Retry-After absolute-date parsing"
status: closed
priority: 1
issue_type: task
created_at: 2026-05-24T09:03:55.219Z
created_by: backlog
updated_at: 2026-05-24T11:54:09.787Z
closed_at: 2026-05-24T11:54:09.787Z
close_reason: Fixed — retry.ml threads now_s through
  classify_error/classify_response/Retry.run (44f46a7)
---

# P1: Plumb a clock into Retry-After absolute-date parsing

## description

Bug: packages/eta-http/client/retry.ml retry_after defaults ?(now_s = 0.0). retry_after_header (line ~109) calls retry_after value with no now_s argument. For an absolute HTTP-date Retry-After header, delay_ms = (epoch_s - 0) * 1000 — multi-decade delay. Retry.run, delay_for_error, delay_for_response never plumb a clock.

Location: packages/eta-http/client/retry.ml retry_after, retry_after_header, delay_for_*, Retry.run

## design

RED test (write first):
1. Compute now_s via the runtime clock capability (or Unix.gettimeofday for the test).
2. Format an HTTP-date string for now_s + 5.0.
3. Drive delay_for_response (or the public Retry.run) against a synthetic 503 response carrying Retry-After: <that date>.
4. Assert the returned delay is within Duration.ms 200 of Duration.seconds 5. Currently fails — delay is roughly epoch_seconds * 1000 ms.

Regression checks:
- Numeric Retry-After: 5 still returns 5s.
- Past-dated Retry-After clamps to zero.

Fix shape:
- Thread the clock through Retry.run via an explicit ?now_s parameter or Capabilities.clock borrowed from the runtime.
- Pass now_s into retry_after_header and retry_after.
- Make retry_after_header private; expose only Retry.run-shaped API to external consumers.

## acceptance criteria

RED test fails on current code and passes after the fix. Numeric and past-dated regressions hold. retry_after_header is no longer publicly exposed.
