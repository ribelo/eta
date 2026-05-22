# C4 Timeout SLO

## Decision

Accept the T7 measured bound as the Phase 6 production SLO:

max_deadline_to_exit_us <= 50_000

The current evidence point is max_deadline_to_exit_us=48417 under the H3
polling discipline.

## Conditions

- Workers poll cancellation at Bind/Map boundaries and at least every 4096
  pure-core loop iterations.
- Deadline payloads remain int64 monotonic nanoseconds.
- Workers compare deadlines locally at polling points.

## Reopen Rule

If Phase 6 implementation or CI remeasurement exceeds 50 ms, lower the pure-loop
poll interval and rerun T2 and T7 before shipping worker-side timeout/retry.
